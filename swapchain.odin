package main

import vk "vendor:vulkan"
import "vendor:glfw"

create_swapchain :: proc(ctx: ^Context) -> bool {
    // Query surface capabilities
    capabilities: vk.SurfaceCapabilitiesKHR
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &capabilities)

    // Choose format
    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, nil)
    formats := make([]vk.SurfaceFormatKHR, format_count)
    defer delete(formats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, raw_data(formats))

    // Use UNORM to match DX9's gamma-incorrect pipeline
    chosen_format := formats[0]
    for &format in formats {
        if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
            chosen_format = format
            break
        }
    }
    ctx.swapchain_format = chosen_format.format

    // Choose extent
    if capabilities.currentExtent.width != max(u32) {
        ctx.swapchain_extent = capabilities.currentExtent
    } else {
        ctx.swapchain_extent = vk.Extent2D{WINDOW_WIDTH, WINDOW_HEIGHT}
    }

    image_count := capabilities.minImageCount + 1
    if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
        image_count = capabilities.maxImageCount
    }

    create_info := vk.SwapchainCreateInfoKHR{
        sType            = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = ctx.surface,
        minImageCount    = image_count,
        imageFormat      = chosen_format.format,
        imageColorSpace  = chosen_format.colorSpace,
        imageExtent      = ctx.swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = {.COLOR_ATTACHMENT},
        preTransform     = capabilities.currentTransform,
        compositeAlpha   = {.OPAQUE},
        presentMode      = .FIFO,
        clipped          = true,
    }

    queue_family_indices := [2]u32{ctx.graphics_family, ctx.present_family}
    if ctx.graphics_family != ctx.present_family {
        create_info.imageSharingMode = .CONCURRENT
        create_info.queueFamilyIndexCount = 2
        create_info.pQueueFamilyIndices = &queue_family_indices[0]
    } else {
        create_info.imageSharingMode = .EXCLUSIVE
    }

    if vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &ctx.swapchain) != .SUCCESS {
        return false
    }

    // Get swapchain images
    vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &image_count, nil)
    ctx.swapchain_images = make([]vk.Image, image_count)
    vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &image_count, raw_data(ctx.swapchain_images))

    // Create image views
    ctx.swapchain_views = make([]vk.ImageView, image_count)
    for i in 0..<image_count {
        view_info := vk.ImageViewCreateInfo{
            sType    = .IMAGE_VIEW_CREATE_INFO,
            image    = ctx.swapchain_images[i],
            viewType = .D2,
            format   = ctx.swapchain_format,
            subresourceRange = vk.ImageSubresourceRange{
                aspectMask     = {.COLOR},
                baseMipLevel   = 0,
                levelCount     = 1,
                baseArrayLayer = 0,
                layerCount     = 1,
            },
        }
        if vk.CreateImageView(ctx.device, &view_info, nil, &ctx.swapchain_views[i]) != .SUCCESS {
            return false
        }
    }

    return true
}

// Clean up swapchain resources (for recreation)
cleanup_swapchain :: proc(ctx: ^Context) {
    vk.DeviceWaitIdle(ctx.device)

    // Destroy depth resources
    vk.DestroyImageView(ctx.device, ctx.depth_view, nil)
    vk.DestroyImage(ctx.device, ctx.depth_image, nil)
    vk.FreeMemory(ctx.device, ctx.depth_memory, nil)

    // Destroy swapchain image views
    for view in ctx.swapchain_views {
        vk.DestroyImageView(ctx.device, view, nil)
    }
    delete(ctx.swapchain_views)
    delete(ctx.swapchain_images)

    // Destroy render_finished semaphores (one per swapchain image)
    for sem in ctx.render_finished {
        vk.DestroySemaphore(ctx.device, sem, nil)
    }
    delete(ctx.render_finished)

    // Destroy swapchain
    vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)
}

// Recreate swapchain after window resize
recreate_swapchain :: proc(ctx: ^Context) -> bool {
    // Handle minimization - wait until window has non-zero size
    width, height := glfw.GetFramebufferSize(ctx.window)
    for width == 0 || height == 0 {
        width, height = glfw.GetFramebufferSize(ctx.window)
        glfw.WaitEvents()
    }

    vk.DeviceWaitIdle(ctx.device)

    // Clean up old swapchain resources
    cleanup_swapchain(ctx)

    // Recreate swapchain
    if !create_swapchain(ctx) {
        log("Failed to recreate swapchain")
        return false
    }

    // Recreate depth resources
    if !create_depth_resources(ctx) {
        log("Failed to recreate depth resources")
        return false
    }

    // Recreate render_finished semaphores (one per swapchain image)
    ctx.render_finished = make([]vk.Semaphore, len(ctx.swapchain_images))
    for i in 0..<len(ctx.swapchain_images) {
        sem_info := vk.SemaphoreCreateInfo{
            sType = .SEMAPHORE_CREATE_INFO,
        }
        if vk.CreateSemaphore(ctx.device, &sem_info, nil, &ctx.render_finished[i]) != .SUCCESS {
            log("Failed to recreate render_finished semaphore")
            return false
        }
    }

    return true
}
