package main

import vk "vendor:vulkan"
import "vendor:glfw"

main_loop :: proc(ctx: ^Context) {
    for !glfw.WindowShouldClose(ctx.window) {
        glfw.PollEvents()
        draw_frame(ctx)
    }

    vk.DeviceWaitIdle(ctx.device)
}

draw_frame :: proc(ctx: ^Context) {
    frame := ctx.current_frame

    // Wait for previous frame
    vk.WaitForFences(ctx.device, 1, &ctx.in_flight_fences[frame], true, max(u64))

    // Acquire image
    image_index: u32
    result := vk.AcquireNextImageKHR(ctx.device, ctx.swapchain, max(u64),
        ctx.image_available[frame], 0, &image_index)

    if result != .SUCCESS {
        return
    }

    vk.ResetFences(ctx.device, 1, &ctx.in_flight_fences[frame])

    // Record command buffer
    cmd := ctx.command_buffers[frame]
    vk.ResetCommandBuffer(cmd, {})

    begin_info := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    vk.BeginCommandBuffer(cmd, &begin_info)

    // Transition swapchain image to color attachment - using Synchronization2
    image_barrier := vk.ImageMemoryBarrier2{
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {.TOP_OF_PIPE},
        srcAccessMask = {},
        dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
        dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
        oldLayout     = .UNDEFINED,
        newLayout     = .COLOR_ATTACHMENT_OPTIMAL,
        image         = ctx.swapchain_images[image_index],
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    depth_barrier := vk.ImageMemoryBarrier2{
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {.TOP_OF_PIPE},
        srcAccessMask = {},
        dstStageMask  = {.EARLY_FRAGMENT_TESTS},
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        oldLayout     = .UNDEFINED,
        newLayout     = .DEPTH_ATTACHMENT_OPTIMAL,
        image         = ctx.depth_image,
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.DEPTH},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    barriers := [2]vk.ImageMemoryBarrier2{image_barrier, depth_barrier}
    dependency_info := vk.DependencyInfo{
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 2,
        pImageMemoryBarriers    = &barriers[0],
    }
    vk.CmdPipelineBarrier2(cmd, &dependency_info)

    // Begin dynamic rendering
    color_attachment := vk.RenderingAttachmentInfo{
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = ctx.swapchain_views[image_index],
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR,
        storeOp     = .STORE,
        clearValue  = vk.ClearValue{color = vk.ClearColorValue{float32 = {0.1, 0.1, 0.1, 1.0}}},
    }

    depth_attachment := vk.RenderingAttachmentInfo{
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = ctx.depth_view,
        imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR,
        storeOp     = .DONT_CARE,
        clearValue  = vk.ClearValue{depthStencil = {depth = 1.0, stencil = 0}},
    }

    rendering_info := vk.RenderingInfo{
        sType                = .RENDERING_INFO,
        renderArea           = vk.Rect2D{extent = ctx.swapchain_extent},
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = &color_attachment,
        pDepthAttachment     = &depth_attachment,
    }

    vk.CmdBeginRendering(cmd, &rendering_info)

    // Bind shader objects (no VkPipeline!)
    stages := [2]vk.ShaderStageFlags{{.VERTEX}, {.FRAGMENT}}
    shaders := [2]vk.ShaderEXT{ctx.vertex_shader, ctx.fragment_shader}
    vk.CmdBindShadersEXT(cmd, 2, &stages[0], &shaders[0])

    // Bind unused shader stages to null
    unused_stages := [3]vk.ShaderStageFlags{{.TESSELLATION_CONTROL}, {.TESSELLATION_EVALUATION}, {.GEOMETRY}}
    null_shaders := [3]vk.ShaderEXT{}
    vk.CmdBindShadersEXT(cmd, 3, &unused_stages[0], &null_shaders[0])

    // Bind descriptor buffer (replaces vkCmdBindDescriptorSets)
    buffer_binding := vk.DescriptorBufferBindingInfoEXT{
        sType   = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        address = ctx.descriptor_buffer_address,
        usage   = {.RESOURCE_DESCRIPTOR_BUFFER_EXT},
    }
    vk.CmdBindDescriptorBuffersEXT(cmd, 1, &buffer_binding)

    // Set descriptor buffer offsets (equivalent to binding descriptor set at index 0)
    buffer_index: u32 = 0
    offset: vk.DeviceSize = 0
    vk.CmdSetDescriptorBufferOffsetsEXT(cmd, .GRAPHICS, ctx.pipeline_layout, 0, 1, &buffer_index, &offset)

    // === ALL DYNAMIC STATE (Extended Dynamic State 1/2/3) ===

    // Viewport and scissor (EDS1)
    viewport := vk.Viewport{
        width    = f32(ctx.swapchain_extent.width),
        height   = f32(ctx.swapchain_extent.height),
        minDepth = 0.0,
        maxDepth = 1.0,
    }
    scissor := vk.Rect2D{extent = ctx.swapchain_extent}
    vk.CmdSetViewportWithCount(cmd, 1, &viewport)
    vk.CmdSetScissorWithCount(cmd, 1, &scissor)

    // Rasterization state (EDS1/2/3)
    vk.CmdSetRasterizerDiscardEnable(cmd, false)
    vk.CmdSetPolygonModeEXT(cmd, .FILL)
    vk.CmdSetCullMode(cmd, {})  // No culling
    vk.CmdSetFrontFace(cmd, .CLOCKWISE)
    vk.CmdSetDepthBiasEnable(cmd, false)
    vk.CmdSetLineWidth(cmd, 1.0)

    // Primitive topology (EDS1)
    vk.CmdSetPrimitiveTopology(cmd, .TRIANGLE_LIST)
    vk.CmdSetPrimitiveRestartEnable(cmd, false)

    // Depth/stencil state (EDS1)
    vk.CmdSetDepthTestEnable(cmd, true)
    vk.CmdSetDepthWriteEnable(cmd, true)
    vk.CmdSetDepthCompareOp(cmd, .LESS)
    vk.CmdSetDepthBoundsTestEnable(cmd, false)
    vk.CmdSetStencilTestEnable(cmd, false)
    vk.CmdSetStencilOp(cmd, {.FRONT, .BACK}, .KEEP, .KEEP, .KEEP, .ALWAYS)

    // Multisample state (EDS3)
    sample_mask: vk.SampleMask = 0xFFFFFFFF
    vk.CmdSetRasterizationSamplesEXT(cmd, {._1})
    vk.CmdSetSampleMaskEXT(cmd, {._1}, &sample_mask)
    vk.CmdSetAlphaToCoverageEnableEXT(cmd, false)

    // Color blend state (EDS3)
    color_blend_enable: b32 = false
    vk.CmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enable)
    color_blend_eq := vk.ColorBlendEquationEXT{
        srcColorBlendFactor = .ONE,
        dstColorBlendFactor = .ZERO,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ZERO,
        alphaBlendOp        = .ADD,
    }
    vk.CmdSetColorBlendEquationEXT(cmd, 0, 1, &color_blend_eq)
    color_write_mask := vk.ColorComponentFlags{.R, .G, .B, .A}
    vk.CmdSetColorWriteMaskEXT(cmd, 0, 1, &color_write_mask)

    // Vertex input (EDS - vertex input dynamic state)
    // No vertex bindings/attributes - using buffer device address
    vk.CmdSetVertexInputEXT(cmd, 0, nil, 0, nil)

    // Push constants with buffer device address
    push := Push_Constants{
        vertices      = ctx.vertex_buffer_address,
        texture_index = 0,
    }
    vk.CmdPushConstants(cmd, ctx.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(Push_Constants), &push)

    // Draw triangle (3 vertices)
    vk.CmdDraw(cmd, 3, 1, 0, 0)

    vk.CmdEndRendering(cmd)

    // Transition to present
    present_barrier := vk.ImageMemoryBarrier2{
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
        srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
        dstStageMask  = {.BOTTOM_OF_PIPE},
        dstAccessMask = {},
        oldLayout     = .COLOR_ATTACHMENT_OPTIMAL,
        newLayout     = .PRESENT_SRC_KHR,
        image         = ctx.swapchain_images[image_index],
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    present_dep := vk.DependencyInfo{
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &present_barrier,
    }
    vk.CmdPipelineBarrier2(cmd, &present_dep)

    vk.EndCommandBuffer(cmd)

    // Submit using Synchronization2
    wait_info := vk.SemaphoreSubmitInfo{
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = ctx.image_available[frame],
        stageMask = {.COLOR_ATTACHMENT_OUTPUT},
    }

    signal_info := vk.SemaphoreSubmitInfo{
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = ctx.render_finished[image_index],  // Per-swapchain-image semaphore
        stageMask = {.ALL_GRAPHICS},
    }

    cmd_info := vk.CommandBufferSubmitInfo{
        sType         = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer = cmd,
    }

    submit_info := vk.SubmitInfo2{
        sType                    = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount   = 1,
        pWaitSemaphoreInfos      = &wait_info,
        commandBufferInfoCount   = 1,
        pCommandBufferInfos      = &cmd_info,
        signalSemaphoreInfoCount = 1,
        pSignalSemaphoreInfos    = &signal_info,
    }

    vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, ctx.in_flight_fences[frame])

    // Present
    swapchains := [1]vk.SwapchainKHR{ctx.swapchain}
    render_finished_sem := ctx.render_finished[image_index]
    present_info := vk.PresentInfoKHR{
        sType              = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &render_finished_sem,
        swapchainCount     = 1,
        pSwapchains        = &swapchains[0],
        pImageIndices      = &image_index,
    }

    vk.QueuePresentKHR(ctx.present_queue, &present_info)

    ctx.current_frame = (frame + 1) % MAX_FRAMES_IN_FLIGHT
}
