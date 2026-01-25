package main

import vk "vendor:vulkan"

create_command_resources :: proc(ctx: ^Context) -> bool {
    pool_info := vk.CommandPoolCreateInfo{
        sType            = .COMMAND_POOL_CREATE_INFO,
        flags            = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = ctx.graphics_family,
    }

    if vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.command_pool) != .SUCCESS {
        return false
    }

    alloc_info := vk.CommandBufferAllocateInfo{
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = ctx.command_pool,
        level              = .PRIMARY,
        commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    }

    if vk.AllocateCommandBuffers(ctx.device, &alloc_info, &ctx.command_buffers[0]) != .SUCCESS {
        return false
    }

    return true
}

create_sync_objects :: proc(ctx: ^Context) -> bool {
    semaphore_info := vk.SemaphoreCreateInfo{
        sType = .SEMAPHORE_CREATE_INFO,
    }

    fence_info := vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }

    // Per-frame semaphores and fences
    for i in 0..<MAX_FRAMES_IN_FLIGHT {
        if vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &ctx.image_available[i]) != .SUCCESS ||
           vk.CreateFence(ctx.device, &fence_info, nil, &ctx.in_flight_fences[i]) != .SUCCESS {
            return false
        }
    }

    // Per-swapchain-image semaphores for render_finished (avoids semaphore reuse issues)
    image_count := len(ctx.swapchain_images)
    ctx.render_finished = make([]vk.Semaphore, image_count)
    for i in 0..<image_count {
        if vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &ctx.render_finished[i]) != .SUCCESS {
            return false
        }
    }

    return true
}
