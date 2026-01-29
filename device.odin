package main

import vk "vendor:vulkan"

pick_physical_device :: proc(ctx: ^Context) -> bool {
    device_count: u32
    vk.EnumeratePhysicalDevices(ctx.instance, &device_count, nil)

    if device_count == 0 {
        return false
    }

    devices := make([]vk.PhysicalDevice, device_count)
    defer delete(devices)
    vk.EnumeratePhysicalDevices(ctx.instance, &device_count, raw_data(devices))

    for device in devices {
        if is_device_suitable(ctx, device) {
            ctx.physical_device = device
            return true
        }
    }

    return false
}

is_device_suitable :: proc(ctx: ^Context, device: vk.PhysicalDevice) -> bool {
    // Check queue families
    queue_family_count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)

    queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
    defer delete(queue_families)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_families))

    graphics_found, present_found := false, false

    for qf, i in queue_families {
        if .GRAPHICS in qf.queueFlags {
            ctx.graphics_family = u32(i)
            graphics_found = true
        }

        present_support: b32
        vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), ctx.surface, &present_support)
        if present_support {
            ctx.present_family = u32(i)
            present_found = true
        }

        if graphics_found && present_found {
            break
        }
    }

    if !graphics_found || !present_found {
        return false
    }

    // Check required features
    features12 := vk.PhysicalDeviceVulkan12Features{
        sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    }
    features13 := vk.PhysicalDeviceVulkan13Features{
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext = &features12,
    }
    features := vk.PhysicalDeviceFeatures2{
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &features13,
    }
    vk.GetPhysicalDeviceFeatures2(device, &features)

    // Verify required features
    if !features12.bufferDeviceAddress || !features12.descriptorIndexing {
        return false
    }
    if !features13.dynamicRendering || !features13.synchronization2 {
        return false
    }

    return true
}

create_logical_device :: proc(ctx: ^Context) -> bool {
    unique_families: map[u32]bool
    defer delete(unique_families)
    unique_families[ctx.graphics_family] = true
    unique_families[ctx.present_family] = true

    queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo)
    defer delete(queue_create_infos)

    queue_priority: f32 = 1.0
    for family in unique_families {
        append(&queue_create_infos, vk.DeviceQueueCreateInfo{
            sType            = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = family,
            queueCount       = 1,
            pQueuePriorities = &queue_priority,
        })
    }

    // Enable all modern features - build pNext chain from bottom up
    descriptor_buffer := vk.PhysicalDeviceDescriptorBufferFeaturesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT,
        descriptorBuffer = true,
    }

    vertex_input_dynamic := vk.PhysicalDeviceVertexInputDynamicStateFeaturesEXT{
        sType = .PHYSICAL_DEVICE_VERTEX_INPUT_DYNAMIC_STATE_FEATURES_EXT,
        pNext = &descriptor_buffer,
        vertexInputDynamicState = true,
    }

    shader_object := vk.PhysicalDeviceShaderObjectFeaturesEXT{
        sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
        pNext = &vertex_input_dynamic,
        shaderObject = true,
    }

    extended_dynamic_state3 := vk.PhysicalDeviceExtendedDynamicState3FeaturesEXT{
        sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
        pNext = &shader_object,
        extendedDynamicState3PolygonMode = true,
        extendedDynamicState3RasterizationSamples = true,
        extendedDynamicState3SampleMask = true,
        extendedDynamicState3AlphaToCoverageEnable = true,
        extendedDynamicState3ColorBlendEnable = true,
        extendedDynamicState3ColorBlendEquation = true,
        extendedDynamicState3ColorWriteMask = true,
    }

    extended_dynamic_state2 := vk.PhysicalDeviceExtendedDynamicState2FeaturesEXT{
        sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
        pNext = &extended_dynamic_state3,
        extendedDynamicState2 = true,
        extendedDynamicState2LogicOp = true,
        extendedDynamicState2PatchControlPoints = true,
    }

    // Note: VK_EXT_extended_dynamic_state (1) is core in Vulkan 1.3
    // All descriptor indexing features are in Vulkan12Features (promoted from extension)
    features12 := vk.PhysicalDeviceVulkan12Features{
        sType                = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        pNext                = &extended_dynamic_state2,
        bufferDeviceAddress  = true,
        descriptorIndexing   = true,
        scalarBlockLayout    = true,
        // Descriptor indexing features (promoted from VK_EXT_descriptor_indexing)
        shaderSampledImageArrayNonUniformIndexing      = true,
        descriptorBindingSampledImageUpdateAfterBind   = true,
        descriptorBindingPartiallyBound                = true,
        descriptorBindingVariableDescriptorCount       = true,
        runtimeDescriptorArray                         = true,
    }

    features13 := vk.PhysicalDeviceVulkan13Features{
        sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext            = &features12,
        dynamicRendering = true,
        synchronization2 = true,
    }

    device_features := vk.PhysicalDeviceFeatures2{
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &features13,
        features = vk.PhysicalDeviceFeatures{
            samplerAnisotropy = true,  // Enable anisotropic filtering
        },
    }

    create_info := vk.DeviceCreateInfo{
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &device_features,
        queueCreateInfoCount    = u32(len(queue_create_infos)),
        pQueueCreateInfos       = raw_data(queue_create_infos),
        enabledExtensionCount   = len(DEVICE_EXTENSIONS),
        ppEnabledExtensionNames = &DEVICE_EXTENSIONS[0],
    }

    if vk.CreateDevice(ctx.physical_device, &create_info, nil, &ctx.device) != .SUCCESS {
        return false
    }

    vk.load_proc_addresses_device(ctx.device)

    vk.GetDeviceQueue(ctx.device, ctx.graphics_family, 0, &ctx.graphics_queue)
    vk.GetDeviceQueue(ctx.device, ctx.present_family, 0, &ctx.present_queue)

    return true
}
