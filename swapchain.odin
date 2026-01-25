package main

import vk "vendor:vulkan"

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

    chosen_format := formats[0]
    for format in formats {
        if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
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
