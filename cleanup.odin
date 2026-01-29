package main

import vk "vendor:vulkan"

cleanup_vulkan :: proc(ctx: ^Context) {
    vk.DeviceWaitIdle(ctx.device)

    // UI resources
    ui_cleanup(ctx)

    // Sync objects
    for i in 0..<MAX_FRAMES_IN_FLIGHT {
        vk.DestroySemaphore(ctx.device, ctx.image_available[i], nil)
        vk.DestroyFence(ctx.device, ctx.in_flight_fences[i], nil)
    }
    for sem in ctx.render_finished {
        vk.DestroySemaphore(ctx.device, sem, nil)
    }
    delete(ctx.render_finished)

    // Vertex buffer
    vk.DestroyBuffer(ctx.device, ctx.vertex_buffer, nil)
    vk.FreeMemory(ctx.device, ctx.vertex_memory, nil)

    // Command pool
    vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

    // Shader objects
    if ctx.vertex_shader != {} {
        vk.DestroyShaderEXT(ctx.device, ctx.vertex_shader, nil)
    }
    if ctx.fragment_shader != {} {
        vk.DestroyShaderEXT(ctx.device, ctx.fragment_shader, nil)
    }
    vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)

    // Textures
    cleanup_textures(ctx)

    // Descriptor buffer
    vk.DestroyBuffer(ctx.device, ctx.descriptor_buffer, nil)
    vk.FreeMemory(ctx.device, ctx.descriptor_buffer_memory, nil)
    vk.DestroyDescriptorSetLayout(ctx.device, ctx.bindless_layout, nil)

    // Lightmap descriptor buffer
    if ctx.lightmap_descriptor_buffer != 0 {
        vk.DestroyBuffer(ctx.device, ctx.lightmap_descriptor_buffer, nil)
    }
    if ctx.lightmap_descriptor_buffer_memory != 0 {
        vk.FreeMemory(ctx.device, ctx.lightmap_descriptor_buffer_memory, nil)
    }
    if ctx.lightmap_layout != 0 {
        vk.DestroyDescriptorSetLayout(ctx.device, ctx.lightmap_layout, nil)
    }

    // Depth
    vk.DestroyImageView(ctx.device, ctx.depth_view, nil)
    vk.DestroyImage(ctx.device, ctx.depth_image, nil)
    vk.FreeMemory(ctx.device, ctx.depth_memory, nil)

    // Swapchain
    for view in ctx.swapchain_views {
        vk.DestroyImageView(ctx.device, view, nil)
    }
    delete(ctx.swapchain_views)
    delete(ctx.swapchain_images)
    vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)

    // Device and instance
    vk.DestroyDevice(ctx.device, nil)
    vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
    vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)
    vk.DestroyInstance(ctx.instance, nil)
}
