package main

import "core:mem"
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

create_bindless_resources :: proc(ctx: ^Context) -> bool {
    // Bindless descriptor set layout for textures - with DESCRIPTOR_BUFFER flag
    binding := vk.DescriptorSetLayoutBinding{
        binding         = 0,
        descriptorType  = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = MAX_BINDLESS_RESOURCES,
        stageFlags      = {.FRAGMENT},
    }

    binding_flags := vk.DescriptorBindingFlags{
        .PARTIALLY_BOUND,
        .VARIABLE_DESCRIPTOR_COUNT,
    }

    flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo{
        sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        bindingCount  = 1,
        pBindingFlags = &binding_flags,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo{
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        pNext        = &flags_info,
        flags        = {.DESCRIPTOR_BUFFER_EXT},  // Use descriptor buffer
        bindingCount = 1,
        pBindings    = &binding,
    }

    if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.bindless_layout) != .SUCCESS {
        return false
    }

    // Get descriptor set layout size
    layout_size: vk.DeviceSize
    vk.GetDescriptorSetLayoutSizeEXT(ctx.device, ctx.bindless_layout, &layout_size)

    // Get descriptor buffer properties for alignment
    desc_buffer_props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    }
    props := vk.PhysicalDeviceProperties2{
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &desc_buffer_props,
    }
    vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props)

    // Align size to descriptor buffer offset alignment
    alignment := desc_buffer_props.descriptorBufferOffsetAlignment
    ctx.descriptor_buffer_size = (layout_size + alignment - 1) & ~(alignment - 1)

    // Create descriptor buffer
    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = ctx.descriptor_buffer_size,
        usage = {.RESOURCE_DESCRIPTOR_BUFFER_EXT, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.descriptor_buffer) != .SUCCESS {
        return false
    }

    // Allocate memory
    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.descriptor_buffer, &mem_requirements)

    flags_alloc := vk.MemoryAllocateFlagsInfo{
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = {.DEVICE_ADDRESS},
    }

    alloc_info := vk.MemoryAllocateInfo{
        sType           = .MEMORY_ALLOCATE_INFO,
        pNext           = &flags_alloc,
        allocationSize  = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.descriptor_buffer_memory) != .SUCCESS {
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.descriptor_buffer, ctx.descriptor_buffer_memory, 0)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.descriptor_buffer,
    }
    ctx.descriptor_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    return true
}

create_vertex_buffer :: proc(ctx: ^Context) -> bool {
    vertices := [?]Vertex{
        {{-0.5, -0.5, 0.0}, {1.0, 0.0, 0.0}, {0.0, 0.0}},
        {{ 0.5, -0.5, 0.0}, {0.0, 1.0, 0.0}, {1.0, 0.0}},
        {{ 0.5,  0.5, 0.0}, {0.0, 0.0, 1.0}, {1.0, 1.0}},
        {{-0.5,  0.5, 0.0}, {1.0, 1.0, 1.0}, {0.0, 1.0}},
    }

    buffer_size := vk.DeviceSize(size_of(vertices))

    // Create buffer with device address
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

    // Need DEVICE_ADDRESS for buffer device address
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
    mem.copy(data, &vertices[0], int(buffer_size))
    vk.UnmapMemory(ctx.device, ctx.vertex_memory)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.vertex_buffer,
    }
    ctx.vertex_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    return true
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
