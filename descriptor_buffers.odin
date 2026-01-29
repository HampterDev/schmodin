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

create_lightmap_descriptor :: proc(ctx: ^Context) -> bool {
    // Descriptor set layout for lightmap (set 1, binding 0)
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

    if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.lightmap_layout) != .SUCCESS {
        log("Failed to create lightmap descriptor set layout")
        return false
    }

    // Get descriptor set layout size
    layout_size: vk.DeviceSize
    vk.GetDescriptorSetLayoutSizeEXT(ctx.device, ctx.lightmap_layout, &layout_size)

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
    ctx.lightmap_descriptor_buffer_size = (layout_size + alignment - 1) & ~(alignment - 1)

    // Create descriptor buffer
    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = ctx.lightmap_descriptor_buffer_size,
        usage = {.RESOURCE_DESCRIPTOR_BUFFER_EXT, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.lightmap_descriptor_buffer) != .SUCCESS {
        log("Failed to create lightmap descriptor buffer")
        return false
    }

    // Allocate memory
    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.lightmap_descriptor_buffer, &mem_requirements)

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

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.lightmap_descriptor_buffer_memory) != .SUCCESS {
        log("Failed to allocate lightmap descriptor buffer memory")
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.lightmap_descriptor_buffer, ctx.lightmap_descriptor_buffer_memory, 0)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.lightmap_descriptor_buffer,
    }
    ctx.lightmap_descriptor_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    log("Lightmap descriptor layout and buffer created")
    return true
}

// Update the lightmap descriptor buffer with the lightmap atlas
update_lightmap_descriptor :: proc(ctx: ^Context) {
    if ctx.lightmap_atlas.view == 0 || ctx.lightmap_sampler == 0 {
        return
    }

    // Map descriptor buffer
    data: rawptr
    vk.MapMemory(ctx.device, ctx.lightmap_descriptor_buffer_memory, 0, ctx.lightmap_descriptor_buffer_size, {}, &data)
    defer vk.UnmapMemory(ctx.device, ctx.lightmap_descriptor_buffer_memory)

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

    // Write lightmap descriptor
    image_info := vk.DescriptorImageInfo{
        sampler     = ctx.lightmap_sampler,
        imageView   = ctx.lightmap_atlas.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }

    desc_info := vk.DescriptorGetInfoEXT{
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type  = .COMBINED_IMAGE_SAMPLER,
        data  = vk.DescriptorDataEXT{pCombinedImageSampler = &image_info},
    }

    vk.GetDescriptorEXT(ctx.device, &desc_info, descriptor_size, data)
    log("Lightmap descriptor buffer updated")
}
