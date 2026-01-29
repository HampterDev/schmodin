package main

import "core:mem"
import "core:fmt"
import vk "vendor:vulkan"

// BMP file header
BMP_Header :: struct #packed {
    signature:      [2]u8,   // "BM"
    file_size:      u32,
    reserved:       u32,
    data_offset:    u32,
}

// BMP info header (BITMAPINFOHEADER)
BMP_Info :: struct #packed {
    header_size:    u32,
    width:          i32,
    height:         i32,
    planes:         u16,
    bits_per_pixel: u16,
    compression:    u32,
    image_size:     u32,
    x_ppm:          i32,
    y_ppm:          i32,
    colors_used:    u32,
    colors_important: u32,
}

// Load BMP from raw data and return RGBA pixels
// Returns nil on failure
load_bmp :: proc(data: []u8) -> (pixels: []u8, width: u32, height: u32, ok: bool) {
    if len(data) < size_of(BMP_Header) + size_of(BMP_Info) {
        return nil, 0, 0, false
    }

    header := (cast(^BMP_Header)&data[0])^
    if header.signature[0] != 'B' || header.signature[1] != 'M' {
        return nil, 0, 0, false
    }

    info := (cast(^BMP_Info)&data[size_of(BMP_Header)])^

    width = u32(info.width)
    height = u32(abs(info.height))
    flip_vertically := info.height > 0  // Positive height means bottom-up

    // Convert to RGBA
    pixels = make([]u8, width * height * 4)

    if info.bits_per_pixel == 8 {
        // 8-bit indexed (palettized) BMP
        // Palette is right after the info header, 4 bytes per entry (BGRA)
        palette_offset := size_of(BMP_Header) + size_of(BMP_Info)
        num_colors := info.colors_used if info.colors_used > 0 else 256

        if len(data) < palette_offset + int(num_colors) * 4 {
            delete(pixels)
            return nil, 0, 0, false
        }

        palette := data[palette_offset:]

        // Row stride for 8bpp (still 4-byte aligned)
        row_stride := ((int(width) + 3) / 4) * 4

        pixel_data := data[header.data_offset:]
        if len(pixel_data) < row_stride * int(height) {
            delete(pixels)
            return nil, 0, 0, false
        }

        for y in 0..<height {
            src_y := flip_vertically ? (height - 1 - y) : y
            src_row := pixel_data[int(src_y) * row_stride:]

            for x in 0..<width {
                palette_idx := int(src_row[x]) * 4
                dst_idx := int(y * width + x) * 4

                // Palette is BGRA, convert to RGBA
                pixels[dst_idx + 0] = palette[palette_idx + 2]  // R
                pixels[dst_idx + 1] = palette[palette_idx + 1]  // G
                pixels[dst_idx + 2] = palette[palette_idx + 0]  // B
                pixels[dst_idx + 3] = 255                        // A (ignore palette alpha)
            }
        }
    } else if info.bits_per_pixel == 24 || info.bits_per_pixel == 32 {
        // 24-bit or 32-bit BMP
        bytes_per_pixel := info.bits_per_pixel / 8
        row_stride := ((int(width) * int(bytes_per_pixel) + 3) / 4) * 4

        pixel_data := data[header.data_offset:]
        if len(pixel_data) < row_stride * int(height) {
            delete(pixels)
            return nil, 0, 0, false
        }

        for y in 0..<height {
            src_y := flip_vertically ? (height - 1 - y) : y
            src_row := pixel_data[int(src_y) * row_stride:]

            for x in 0..<width {
                src_idx := int(x) * int(bytes_per_pixel)
                dst_idx := int(y * width + x) * 4

                // BMP is BGR(A), convert to RGBA
                pixels[dst_idx + 0] = src_row[src_idx + 2]  // R
                pixels[dst_idx + 1] = src_row[src_idx + 1]  // G
                pixels[dst_idx + 2] = src_row[src_idx + 0]  // B
                pixels[dst_idx + 3] = bytes_per_pixel == 4 ? src_row[src_idx + 3] : 255  // A
            }
        }
    } else {
        fmt.eprintln("Unsupported BMP format:", info.bits_per_pixel, "bpp")
        delete(pixels)
        return nil, 0, 0, false
    }

    return pixels, width, height, true
}

// Create a Vulkan texture from RGBA pixel data
create_texture :: proc(ctx: ^Context, pixels: []u8, width: u32, height: u32) -> (tex: Texture, ok: bool) {
    image_size := vk.DeviceSize(width * height * 4)

    // Create staging buffer
    staging_buffer: vk.Buffer
    staging_memory: vk.DeviceMemory

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = image_size,
        usage = {.TRANSFER_SRC},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &staging_buffer) != .SUCCESS {
        return {}, false
    }
    defer vk.DestroyBuffer(ctx.device, staging_buffer, nil)

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, staging_buffer, &mem_requirements)

    alloc_info := vk.MemoryAllocateInfo{
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &staging_memory) != .SUCCESS {
        return {}, false
    }
    defer vk.FreeMemory(ctx.device, staging_memory, nil)

    vk.BindBufferMemory(ctx.device, staging_buffer, staging_memory, 0)

    // Copy pixel data to staging buffer
    data: rawptr
    vk.MapMemory(ctx.device, staging_memory, 0, image_size, {}, &data)
    mem.copy(data, raw_data(pixels), int(image_size))
    vk.UnmapMemory(ctx.device, staging_memory)

    // Create image
    image_info := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = .R8G8B8A8_UNORM,  // UNORM to match DX9 gamma-incorrect pipeline
        extent      = vk.Extent3D{width, height, 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = .OPTIMAL,
        usage       = {.TRANSFER_DST, .SAMPLED},
        initialLayout = .UNDEFINED,
    }

    if vk.CreateImage(ctx.device, &image_info, nil, &tex.image) != .SUCCESS {
        return {}, false
    }

    vk.GetImageMemoryRequirements(ctx.device, tex.image, &mem_requirements)

    alloc_info.allocationSize = mem_requirements.size
    alloc_info.memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL})

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &tex.memory) != .SUCCESS {
        vk.DestroyImage(ctx.device, tex.image, nil)
        return {}, false
    }

    vk.BindImageMemory(ctx.device, tex.image, tex.memory, 0)

    // Transition and copy using a one-shot command buffer
    cmd := begin_single_command(ctx)

    // Transition to transfer dst
    barrier := vk.ImageMemoryBarrier{
        sType               = .IMAGE_MEMORY_BARRIER,
        srcAccessMask       = {},
        dstAccessMask       = {.TRANSFER_WRITE},
        oldLayout           = .UNDEFINED,
        newLayout           = .TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image               = tex.image,
        subresourceRange    = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }
    vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)

    // Copy buffer to image
    region := vk.BufferImageCopy{
        bufferOffset      = 0,
        bufferRowLength   = 0,
        bufferImageHeight = 0,
        imageSubresource  = vk.ImageSubresourceLayers{
            aspectMask     = {.COLOR},
            mipLevel       = 0,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
        imageOffset = {0, 0, 0},
        imageExtent = {width, height, 1},
    }
    vk.CmdCopyBufferToImage(cmd, staging_buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

    // Transition to shader read
    barrier.srcAccessMask = {.TRANSFER_WRITE}
    barrier.dstAccessMask = {.SHADER_READ}
    barrier.oldLayout = .TRANSFER_DST_OPTIMAL
    barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
    vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)

    end_single_command(ctx, cmd)

    // Create image view
    view_info := vk.ImageViewCreateInfo{
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = tex.image,
        viewType = .D2,
        format   = .R8G8B8A8_UNORM,
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    if vk.CreateImageView(ctx.device, &view_info, nil, &tex.view) != .SUCCESS {
        vk.DestroyImage(ctx.device, tex.image, nil)
        vk.FreeMemory(ctx.device, tex.memory, nil)
        return {}, false
    }

    tex.width = width
    tex.height = height
    return tex, true
}

// Create a Vulkan texture from R8G8B8A8 pixel data (32-bit per pixel)
// Full quality lightmap - posterization is now done in shader when enabled
create_lightmap_texture :: proc(ctx: ^Context, pixels: []u32, width: u32, height: u32) -> (tex: Texture, ok: bool) {
    image_size := vk.DeviceSize(width * height * 4)  // 4 bytes per pixel

    // Create staging buffer
    staging_buffer: vk.Buffer
    staging_memory: vk.DeviceMemory

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = image_size,
        usage = {.TRANSFER_SRC},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &staging_buffer) != .SUCCESS {
        return {}, false
    }
    defer vk.DestroyBuffer(ctx.device, staging_buffer, nil)

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, staging_buffer, &mem_requirements)

    alloc_info := vk.MemoryAllocateInfo{
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &staging_memory) != .SUCCESS {
        return {}, false
    }
    defer vk.FreeMemory(ctx.device, staging_memory, nil)

    vk.BindBufferMemory(ctx.device, staging_buffer, staging_memory, 0)

    // Copy pixel data to staging buffer
    data: rawptr
    vk.MapMemory(ctx.device, staging_memory, 0, image_size, {}, &data)
    mem.copy(data, raw_data(pixels), int(image_size))
    vk.UnmapMemory(ctx.device, staging_memory)

    // Create image with R8G8B8A8 format (full quality)
    image_info := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = .R8G8B8A8_UNORM,  // Full 8-bit per channel
        extent      = vk.Extent3D{width, height, 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = .OPTIMAL,
        usage       = {.TRANSFER_DST, .SAMPLED},
        initialLayout = .UNDEFINED,
    }

    if vk.CreateImage(ctx.device, &image_info, nil, &tex.image) != .SUCCESS {
        return {}, false
    }

    vk.GetImageMemoryRequirements(ctx.device, tex.image, &mem_requirements)

    alloc_info.allocationSize = mem_requirements.size
    alloc_info.memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL})

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &tex.memory) != .SUCCESS {
        vk.DestroyImage(ctx.device, tex.image, nil)
        return {}, false
    }

    vk.BindImageMemory(ctx.device, tex.image, tex.memory, 0)

    // Transition and copy using a one-shot command buffer
    cmd := begin_single_command(ctx)

    // Transition to transfer dst
    barrier := vk.ImageMemoryBarrier{
        sType               = .IMAGE_MEMORY_BARRIER,
        srcAccessMask       = {},
        dstAccessMask       = {.TRANSFER_WRITE},
        oldLayout           = .UNDEFINED,
        newLayout           = .TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image               = tex.image,
        subresourceRange    = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }
    vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)

    // Copy buffer to image
    region := vk.BufferImageCopy{
        bufferOffset      = 0,
        bufferRowLength   = 0,
        bufferImageHeight = 0,
        imageSubresource  = vk.ImageSubresourceLayers{
            aspectMask     = {.COLOR},
            mipLevel       = 0,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
        imageOffset = {0, 0, 0},
        imageExtent = {width, height, 1},
    }
    vk.CmdCopyBufferToImage(cmd, staging_buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

    // Transition to shader read
    barrier.srcAccessMask = {.TRANSFER_WRITE}
    barrier.dstAccessMask = {.SHADER_READ}
    barrier.oldLayout = .TRANSFER_DST_OPTIMAL
    barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
    vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)

    end_single_command(ctx, cmd)

    // Create image view
    view_info := vk.ImageViewCreateInfo{
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = tex.image,
        viewType = .D2,
        format   = .R8G8B8A8_UNORM,
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    if vk.CreateImageView(ctx.device, &view_info, nil, &tex.view) != .SUCCESS {
        vk.DestroyImage(ctx.device, tex.image, nil)
        vk.FreeMemory(ctx.device, tex.memory, nil)
        return {}, false
    }

    tex.width = width
    tex.height = height
    return tex, true
}

// Helper to begin a single-use command buffer
begin_single_command :: proc(ctx: ^Context) -> vk.CommandBuffer {
    alloc_info := vk.CommandBufferAllocateInfo{
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = ctx.command_pool,
        level              = .PRIMARY,
        commandBufferCount = 1,
    }

    cmd: vk.CommandBuffer
    vk.AllocateCommandBuffers(ctx.device, &alloc_info, &cmd)

    begin_info := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    vk.BeginCommandBuffer(cmd, &begin_info)

    return cmd
}

// Helper to end and submit a single-use command buffer
end_single_command :: proc(ctx: ^Context, cmd: vk.CommandBuffer) {
    vk.EndCommandBuffer(cmd)

    // Copy to local variable to take address
    cmd_buf := cmd
    submit_info := vk.SubmitInfo{
        sType              = .SUBMIT_INFO,
        commandBufferCount = 1,
        pCommandBuffers    = &cmd_buf,
    }
    vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, 0)
    vk.QueueWaitIdle(ctx.graphics_queue)

    vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buf)
}

// Create a texture sampler
create_sampler :: proc(ctx: ^Context) -> (sampler: vk.Sampler, ok: bool) {
    sampler_info := vk.SamplerCreateInfo{
        sType        = .SAMPLER_CREATE_INFO,
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        mipmapMode   = .LINEAR,
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        mipLodBias   = 0,
        anisotropyEnable = true,   // 8x anisotropic filtering like C++ version
        maxAnisotropy    = 8,
        compareEnable    = false,
        minLod           = 0,
        maxLod           = 0,
        borderColor      = .FLOAT_OPAQUE_BLACK,
    }

    if vk.CreateSampler(ctx.device, &sampler_info, nil, &sampler) != .SUCCESS {
        return 0, false
    }
    return sampler, true
}

// Destroy a texture
destroy_texture :: proc(ctx: ^Context, tex: ^Texture) {
    if tex.view != 0 {
        vk.DestroyImageView(ctx.device, tex.view, nil)
    }
    if tex.image != 0 {
        vk.DestroyImage(ctx.device, tex.image, nil)
    }
    if tex.memory != 0 {
        vk.FreeMemory(ctx.device, tex.memory, nil)
    }
    tex^ = {}
}

// Load ground textures from GRF based on GND texture list
load_ground_textures :: proc(ctx: ^Context, grf: ^Grf, gnd: ^GND_Ground) -> bool {
    if len(gnd.textures) == 0 {
        return true  // No textures to load
    }

    // Create sampler
    sampler, sampler_ok := create_sampler(ctx)
    if !sampler_ok {
        log("Failed to create texture sampler")
        return false
    }
    ctx.sampler = sampler

    ctx.textures = make([]Texture, len(gnd.textures))

    for tex_name, i in gnd.textures {
        // Build full path: data\texture\<texture_name>
        full_path := fmt.tprintf("data\\texture\\%s", tex_name)

        // Load from GRF
        bmp_data, ok := grf_get_data(grf, full_path)
        if !ok {
            log_fmt("Failed to load texture: %s", full_path)
            // Create a pink placeholder texture
            ctx.textures[i] = create_placeholder_texture(ctx)
            continue
        }
        defer delete(bmp_data)

        // Parse BMP
        pixels, width, height, bmp_ok := load_bmp(bmp_data)
        if !bmp_ok {
            log_fmt("Failed to parse BMP: %s", full_path)
            ctx.textures[i] = create_placeholder_texture(ctx)
            continue
        }
        defer delete(pixels)

        // Create Vulkan texture
        tex, tex_ok := create_texture(ctx, pixels, width, height)
        if !tex_ok {
            log_fmt("Failed to create texture: %s", full_path)
            ctx.textures[i] = create_placeholder_texture(ctx)
            continue
        }

        ctx.textures[i] = tex
    }

    log_fmt("Loaded %d ground textures", len(ctx.textures))

    // Create lightmap atlas
    if !create_lightmap_atlas(ctx, gnd) {
        log("Warning: Failed to create lightmap atlas")
    }

    // Update descriptor buffer with textures
    update_descriptor_buffer(ctx)

    // Update lightmap descriptor buffer
    update_lightmap_descriptor(ctx)

    return true
}

// Cell size matches lightmap size (8x8, same as original game)
LMAP_CELL_SIZE :: LMAP_WIDTH  // 8

// Calculate atlas dimensions to fit N lightmaps (each 8x8)
// Returns atlas width/height in pixels and cells per row
calc_atlas_size :: proc(num_lightmaps: int) -> (width: u32, height: u32, cells_per_row: u32) {
    if num_lightmaps == 0 {
        return LMAP_CELL_SIZE, LMAP_CELL_SIZE, 1
    }

    // Find smallest power-of-2 square that fits all lightmaps
    cells_needed := u32(num_lightmaps)
    cells_per_row = 1
    for cells_per_row * cells_per_row < cells_needed {
        cells_per_row *= 2
    }

    // Each lightmap cell is 8x8 pixels
    width = cells_per_row * LMAP_CELL_SIZE
    height = ((cells_needed + cells_per_row - 1) / cells_per_row) * LMAP_CELL_SIZE
    // Round height up to power of 2
    h: u32 = LMAP_CELL_SIZE
    for h < height {
        h *= 2
    }
    height = h

    return width, height, cells_per_row
}

// Create lightmap atlas texture from GND lightmap data
// Uses R8G8B8A8_UNORM format for full quality - posterization is done in shader
create_lightmap_atlas :: proc(ctx: ^Context, gnd: ^GND_Ground) -> bool {
    num_lightmaps := len(gnd.lightmaps)
    if num_lightmaps == 0 {
        log("No lightmaps to create atlas")
        return true
    }

    // Calculate atlas size
    atlas_width, atlas_height, cells_per_row := calc_atlas_size(num_lightmaps)
    log_fmt("Creating lightmap atlas: %dx%d (%d lightmaps, %d per row) [R8G8B8A8]",
            atlas_width, atlas_height, num_lightmaps, cells_per_row)

    // Allocate R8G8B8A8 pixels (32-bit per pixel)
    pixels := make([]u32, atlas_width * atlas_height)
    defer delete(pixels)

    // Initialize to neutral (mid-gray specular, full intensity shadow)
    // R8G8B8A8: R | (G << 8) | (B << 16) | (A << 24)
    // 128 = mid-gray, 255 = full intensity
    for i := 0; i < int(atlas_width * atlas_height); i += 1 {
        pixels[i] = 128 | (128 << 8) | (128 << 16) | (255 << 24)
    }

    // Copy each lightmap into the atlas
    for lm, idx in gnd.lightmaps {
        // Calculate position in atlas
        cell_x := u32(idx) % cells_per_row
        cell_y := u32(idx) / cells_per_row
        base_x := cell_x * LMAP_CELL_SIZE
        base_y := cell_y * LMAP_CELL_SIZE

        // Copy 8x8 lightmap
        for y in 0..<LMAP_HEIGHT {
            for x in 0..<LMAP_WIDTH {
                px := base_x + u32(x)
                py := base_y + u32(y)
                dst_idx := int(py * atlas_width + px)

                // Get source values (8-bit)
                intensity := lm.intensity[y][x]
                spec_r := lm.specular[y][x][0]
                spec_g := lm.specular[y][x][1]
                spec_b := lm.specular[y][x][2]

                // Pack into R8G8B8A8 (32-bit)
                // VK_FORMAT_R8G8B8A8_UNORM: R in bits 0-7, G in 8-15, B in 16-23, A in 24-31
                pixels[dst_idx] = u32(spec_r) | (u32(spec_g) << 8) | (u32(spec_b) << 16) | (u32(intensity) << 24)
            }
        }
    }

    // Create Vulkan texture with R8G8B8A8 format
    tex, ok := create_lightmap_texture(ctx, pixels, atlas_width, atlas_height)
    if !ok {
        log("Failed to create lightmap atlas texture")
        return false
    }

    ctx.lightmap_atlas = tex

    // Create lightmap sampler (linear filtering, clamp to border with opaque black)
    // D3D trace: Stage 1 uses D3DTADDRESS_BORDER with BORDERCOLOR=0xFF000000
    sampler_info := vk.SamplerCreateInfo{
        sType        = .SAMPLER_CREATE_INFO,
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        mipmapMode   = .NEAREST,
        addressModeU = .CLAMP_TO_BORDER,
        addressModeV = .CLAMP_TO_BORDER,
        addressModeW = .CLAMP_TO_BORDER,
        mipLodBias   = 0,
        anisotropyEnable = false,
        maxAnisotropy    = 1,
        compareEnable    = false,
        minLod           = 0,
        maxLod           = 0,
        borderColor      = .FLOAT_OPAQUE_BLACK,
    }

    if vk.CreateSampler(ctx.device, &sampler_info, nil, &ctx.lightmap_sampler) != .SUCCESS {
        log("Failed to create lightmap sampler")
        return false
    }

    log_fmt("Lightmap atlas created: %dx%d", atlas_width, atlas_height)
    return true
}

// Create a placeholder pink texture for missing textures
create_placeholder_texture :: proc(ctx: ^Context) -> Texture {
    pixels := make([]u8, 4 * 4 * 4)  // 4x4 pink texture
    defer delete(pixels)

    for i := 0; i < 16; i += 1 {
        pixels[i * 4 + 0] = 255  // R
        pixels[i * 4 + 1] = 0    // G
        pixels[i * 4 + 2] = 255  // B
        pixels[i * 4 + 3] = 255  // A
    }

    tex, _ := create_texture(ctx, pixels, 4, 4)
    return tex
}

// Update the descriptor buffer with texture descriptors
update_descriptor_buffer :: proc(ctx: ^Context) {
    if len(ctx.textures) == 0 || ctx.sampler == 0 {
        return
    }

    // Map descriptor buffer
    data: rawptr
    vk.MapMemory(ctx.device, ctx.descriptor_buffer_memory, 0, ctx.descriptor_buffer_size, {}, &data)
    defer vk.UnmapMemory(ctx.device, ctx.descriptor_buffer_memory)

    // Get descriptor size
    desc_props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    }
    props := vk.PhysicalDeviceProperties2{
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &desc_props,
    }
    vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props)

    descriptor_size := desc_props.combinedImageSamplerDescriptorSize

    // Write descriptors for each texture
    for tex, i in ctx.textures {
        image_info := vk.DescriptorImageInfo{
            sampler     = ctx.sampler,
            imageView   = tex.view,
            imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        }

        desc_info := vk.DescriptorGetInfoEXT{
            sType = .DESCRIPTOR_GET_INFO_EXT,
            type  = .COMBINED_IMAGE_SAMPLER,
            data  = vk.DescriptorDataEXT{pCombinedImageSampler = &image_info},
        }

        offset := uint(i) * uint(descriptor_size)
        vk.GetDescriptorEXT(ctx.device, &desc_info, descriptor_size, rawptr(uintptr(data) + uintptr(offset)))
    }
}

// Cleanup all textures
cleanup_textures :: proc(ctx: ^Context) {
    for &tex in ctx.textures {
        destroy_texture(ctx, &tex)
    }
    delete(ctx.textures)

    if ctx.sampler != 0 {
        vk.DestroySampler(ctx.device, ctx.sampler, nil)
        ctx.sampler = 0
    }

    // Cleanup lightmap atlas
    destroy_texture(ctx, &ctx.lightmap_atlas)
    if ctx.lightmap_sampler != 0 {
        vk.DestroySampler(ctx.device, ctx.lightmap_sampler, nil)
        ctx.lightmap_sampler = 0
    }
}
