package main

import vk "vendor:vulkan"

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

// Create descriptor layout and buffers for map atlases (shadow, light, lighting)
create_map_atlas_descriptors :: proc(ctx: ^Context) -> bool {
    // Shared descriptor set layout for all atlas textures (1 combined image sampler each)
    binding := vk.DescriptorSetLayoutBinding{
        binding         = 0,
        descriptorType  = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags      = {.FRAGMENT},
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo{
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        flags        = {.DESCRIPTOR_BUFFER_EXT},
        bindingCount = 1,
        pBindings    = &binding,
    }

    if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.map_atlas_layout) != .SUCCESS {
        log("Failed to create map atlas descriptor set layout")
        return false
    }

    // Get descriptor set layout size
    layout_size: vk.DeviceSize
    vk.GetDescriptorSetLayoutSizeEXT(ctx.device, ctx.map_atlas_layout, &layout_size)

    // Get descriptor buffer properties for alignment
    desc_buffer_props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    }
    props := vk.PhysicalDeviceProperties2{
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &desc_buffer_props,
    }
    vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props)

    alignment := desc_buffer_props.descriptorBufferOffsetAlignment
    ctx.map_descriptor_size = (layout_size + alignment - 1) & ~(alignment - 1)

    // Helper to create a descriptor buffer
    create_atlas_descriptor_buffer :: proc(ctx: ^Context, buffer: ^vk.Buffer, memory: ^vk.DeviceMemory, address: ^vk.DeviceAddress) -> bool {
        buffer_info := vk.BufferCreateInfo{
            sType = .BUFFER_CREATE_INFO,
            size  = ctx.map_descriptor_size,
            usage = {.RESOURCE_DESCRIPTOR_BUFFER_EXT, .SHADER_DEVICE_ADDRESS},
        }

        if vk.CreateBuffer(ctx.device, &buffer_info, nil, buffer) != .SUCCESS {
            return false
        }

        mem_requirements: vk.MemoryRequirements
        vk.GetBufferMemoryRequirements(ctx.device, buffer^, &mem_requirements)

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

        if vk.AllocateMemory(ctx.device, &alloc_info, nil, memory) != .SUCCESS {
            return false
        }

        vk.BindBufferMemory(ctx.device, buffer^, memory^, 0)

        address_info := vk.BufferDeviceAddressInfo{
            sType  = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = buffer^,
        }
        address^ = vk.GetBufferDeviceAddress(ctx.device, &address_info)

        return true
    }

    // Create descriptor buffers for all three atlases
    if !create_atlas_descriptor_buffer(ctx, &ctx.shadow_descriptor_buffer, &ctx.shadow_descriptor_memory, &ctx.shadow_descriptor_address) {
        log("Failed to create shadow descriptor buffer")
        return false
    }
    if !create_atlas_descriptor_buffer(ctx, &ctx.light_descriptor_buffer, &ctx.light_descriptor_memory, &ctx.light_descriptor_address) {
        log("Failed to create light descriptor buffer")
        return false
    }
    if !create_atlas_descriptor_buffer(ctx, &ctx.lighting_descriptor_buffer, &ctx.lighting_descriptor_memory, &ctx.lighting_descriptor_address) {
        log("Failed to create lighting descriptor buffer")
        return false
    }
    if !create_atlas_descriptor_buffer(ctx, &ctx.half_lambert_descriptor_buffer, &ctx.half_lambert_descriptor_memory, &ctx.half_lambert_descriptor_address) {
        log("Failed to create half-lambert descriptor buffer")
        return false
    }

    log("Map atlas descriptor layout and buffers created")
    return true
}

// Update a single atlas descriptor buffer
update_atlas_descriptor :: proc(ctx: ^Context, atlas: ^Texture, memory: vk.DeviceMemory) {
    if atlas.view == 0 || ctx.map_sampler == 0 {
        return
    }

    data: rawptr
    vk.MapMemory(ctx.device, memory, 0, ctx.map_descriptor_size, {}, &data)
    defer vk.UnmapMemory(ctx.device, memory)

    desc_props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    }
    props := vk.PhysicalDeviceProperties2{
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &desc_props,
    }
    vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props)

    descriptor_size := desc_props.combinedImageSamplerDescriptorSize

    image_info := vk.DescriptorImageInfo{
        sampler     = ctx.map_sampler,
        imageView   = atlas.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }

    desc_info := vk.DescriptorGetInfoEXT{
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type  = .COMBINED_IMAGE_SAMPLER,
        data  = vk.DescriptorDataEXT{pCombinedImageSampler = &image_info},
    }

    vk.GetDescriptorEXT(ctx.device, &desc_info, descriptor_size, data)
}

// Update all map atlas descriptors
update_map_atlas_descriptors :: proc(ctx: ^Context) {
    update_atlas_descriptor(ctx, &ctx.shadow_atlas, ctx.shadow_descriptor_memory)
    update_atlas_descriptor(ctx, &ctx.light_atlas, ctx.light_descriptor_memory)
    update_atlas_descriptor(ctx, &ctx.lighting_atlas, ctx.lighting_descriptor_memory)
    update_atlas_descriptor(ctx, &ctx.half_lambert_atlas, ctx.half_lambert_descriptor_memory)
    log("Map atlas descriptor buffers updated")
}
