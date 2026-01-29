package main

import vk "vendor:vulkan"
import "vendor:glfw"

main_loop :: proc(ctx: ^Context) {
    last_time := glfw.GetTime()

    for !glfw.WindowShouldClose(ctx.window) {
        current_time := glfw.GetTime()
        delta_time := f32(current_time - last_time)
        last_time = current_time

        glfw.PollEvents()

        // Process UI input and build UI
        ui_process_input(ctx)
        ui_build(ctx)

        // Handle map reload if requested
        if ctx.map_needs_reload && len(ctx.available_maps) > 0 {
            ctx.map_needs_reload = false
            new_map := ctx.available_maps[ctx.current_map_index]
            reload_map(ctx, new_map)
        }

        update_camera(ctx, delta_time)
        draw_frame(ctx)
    }

    vk.DeviceWaitIdle(ctx.device)
}

// Update camera based on keyboard and mouse input
update_camera :: proc(ctx: ^Context, dt: f32) {
    move_speed: f32 = 200.0  // Units per second
    look_speed: f32 = 1.5    // Radians per second
    mouse_sensitivity: f32 = 0.003  // Radians per pixel

    // Get direction vectors from quaternion
    forward := quat_forward(ctx.camera_rot)
    right := quat_right(ctx.camera_rot)

    // Movement (WASD) - move along XZ plane only
    forward_xz := vec3_normalize(Vec3{forward.x, 0, forward.z})
    right_xz := vec3_normalize(Vec3{right.x, 0, right.z})

    if glfw.GetKey(ctx.window, glfw.KEY_W) == glfw.PRESS {
        ctx.camera_pos.x += forward_xz.x * move_speed * dt
        ctx.camera_pos.z += forward_xz.z * move_speed * dt
    }
    if glfw.GetKey(ctx.window, glfw.KEY_S) == glfw.PRESS {
        ctx.camera_pos.x -= forward_xz.x * move_speed * dt
        ctx.camera_pos.z -= forward_xz.z * move_speed * dt
    }
    if glfw.GetKey(ctx.window, glfw.KEY_A) == glfw.PRESS {
        ctx.camera_pos.x -= right_xz.x * move_speed * dt
        ctx.camera_pos.z -= right_xz.z * move_speed * dt
    }
    if glfw.GetKey(ctx.window, glfw.KEY_D) == glfw.PRESS {
        ctx.camera_pos.x += right_xz.x * move_speed * dt
        ctx.camera_pos.z += right_xz.z * move_speed * dt
    }

    // Up/Down (Space/Ctrl)
    if glfw.GetKey(ctx.window, glfw.KEY_SPACE) == glfw.PRESS {
        ctx.camera_pos.y += move_speed * dt
    }
    if glfw.GetKey(ctx.window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS {
        ctx.camera_pos.y -= move_speed * dt
    }

    // Skip mouse/scroll camera controls when UI is active
    ui_active := ui_wants_mouse()

    // Mouse scroll zoom (move along forward direction)
    if ctx.scroll_delta != 0 {
        if !ui_active {
            zoom_speed: f32 = 50.0  // Units per scroll tick
            ctx.camera_pos.x += forward.x * ctx.scroll_delta * zoom_speed
            ctx.camera_pos.y += forward.y * ctx.scroll_delta * zoom_speed
            ctx.camera_pos.z += forward.z * ctx.scroll_delta * zoom_speed
        }
        ctx.scroll_delta = 0  // Always reset after consuming
    }

    // Right mouse button drag for looking around
    mouse_x, mouse_y := glfw.GetCursorPos(ctx.window)
    rmb_pressed := glfw.GetMouseButton(ctx.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS

    if rmb_pressed && !ui_active {
        if ctx.mouse_captured {
            // Calculate mouse delta
            delta_x := f32(mouse_x - ctx.last_mouse_x)
            delta_y := f32(mouse_y - ctx.last_mouse_y)

            // Yaw rotation (horizontal mouse movement)
            if delta_x != 0 {
                yaw_rot := quat_from_axis_angle(Vec3{0, 1, 0}, delta_x * mouse_sensitivity)
                ctx.camera_rot = quat_normalize(quat_mul(yaw_rot, ctx.camera_rot))
            }

            // Pitch rotation (vertical mouse movement)
            if delta_y != 0 {
                pitch_rot := quat_from_axis_angle(Vec3{1, 0, 0}, delta_y * mouse_sensitivity)
                ctx.camera_rot = quat_normalize(quat_mul(ctx.camera_rot, pitch_rot))
            }
        }
        ctx.mouse_captured = true
    } else {
        ctx.mouse_captured = false
    }
    ctx.last_mouse_x = mouse_x
    ctx.last_mouse_y = mouse_y

    // Toggle fog with F key (edge triggered)
    f_pressed := glfw.GetKey(ctx.window, glfw.KEY_F) == glfw.PRESS
    if f_pressed && !ctx.f_key_was_pressed {
        ctx.fog_enabled = !ctx.fog_enabled
    }
    ctx.f_key_was_pressed = f_pressed

    // Cycle polygon mode with V key (FILL -> LINE -> POINT -> FILL)
    v_pressed := glfw.GetKey(ctx.window, glfw.KEY_V) == glfw.PRESS
    if v_pressed && !ctx.v_key_was_pressed {
        ctx.polygon_mode = (ctx.polygon_mode + 1) % 3
    }
    ctx.v_key_was_pressed = v_pressed

    // Toggle fullscreen with F11
    f11_pressed := glfw.GetKey(ctx.window, glfw.KEY_F11) == glfw.PRESS
    if f11_pressed && !ctx.f11_key_was_pressed {
        toggle_fullscreen(ctx)
    }
    ctx.f11_key_was_pressed = f11_pressed

    // Arrow keys still work for looking around
    if glfw.GetKey(ctx.window, glfw.KEY_LEFT) == glfw.PRESS {
        yaw_rot := quat_from_axis_angle(Vec3{0, 1, 0}, -look_speed * dt)
        ctx.camera_rot = quat_normalize(quat_mul(yaw_rot, ctx.camera_rot))
    }
    if glfw.GetKey(ctx.window, glfw.KEY_RIGHT) == glfw.PRESS {
        yaw_rot := quat_from_axis_angle(Vec3{0, 1, 0}, look_speed * dt)
        ctx.camera_rot = quat_normalize(quat_mul(yaw_rot, ctx.camera_rot))
    }
    if glfw.GetKey(ctx.window, glfw.KEY_UP) == glfw.PRESS {
        pitch_rot := quat_from_axis_angle(Vec3{1, 0, 0}, -look_speed * dt)
        ctx.camera_rot = quat_normalize(quat_mul(ctx.camera_rot, pitch_rot))
    }
    if glfw.GetKey(ctx.window, glfw.KEY_DOWN) == glfw.PRESS {
        pitch_rot := quat_from_axis_angle(Vec3{1, 0, 0}, look_speed * dt)
        ctx.camera_rot = quat_normalize(quat_mul(ctx.camera_rot, pitch_rot))
    }
}

draw_frame :: proc(ctx: ^Context) {
    frame := ctx.current_frame

    // Wait for previous frame
    vk.WaitForFences(ctx.device, 1, &ctx.in_flight_fences[frame], true, max(u64))

    // Acquire image
    image_index: u32
    result := vk.AcquireNextImageKHR(ctx.device, ctx.swapchain, max(u64),
        ctx.image_available[frame], 0, &image_index)

    if result == .ERROR_OUT_OF_DATE_KHR {
        recreate_swapchain(ctx)
        return
    } else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
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
        clearValue  = vk.ClearValue{color = vk.ClearColorValue{float32 = {0.0, 0.0, 0.0, 1.0}}},
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

    // Bind descriptor buffers (replaces vkCmdBindDescriptorSets)
    // Buffer 0: bindless textures (set 0), Buffer 1: lightmap (set 1)
    buffer_bindings := [2]vk.DescriptorBufferBindingInfoEXT{
        {
            sType   = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            address = ctx.descriptor_buffer_address,
            usage   = {.RESOURCE_DESCRIPTOR_BUFFER_EXT},
        },
        {
            sType   = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            address = ctx.lightmap_descriptor_buffer_address,
            usage   = {.RESOURCE_DESCRIPTOR_BUFFER_EXT},
        },
    }
    vk.CmdBindDescriptorBuffersEXT(cmd, 2, &buffer_bindings[0])

    // Set descriptor buffer offsets for both sets
    // buffer_indices[i] tells which bound buffer to use for set i
    buffer_indices := [2]u32{0, 1}  // Set 0 uses buffer 0, Set 1 uses buffer 1
    offsets := [2]vk.DeviceSize{0, 0}
    vk.CmdSetDescriptorBufferOffsetsEXT(cmd, .GRAPHICS, ctx.pipeline_layout, 0, 2, &buffer_indices[0], &offsets[0])

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
    polygon_modes := [3]vk.PolygonMode{.FILL, .LINE, .POINT}
    vk.CmdSetPolygonModeEXT(cmd, polygon_modes[ctx.polygon_mode])
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

    // Push constants with buffer device address and MVP matrix
    push := Push_Constants{
        mvp               = camera_get_vp_matrix(ctx),
        vertices          = ctx.vertex_buffer_address,
        texture_index     = 0,
        ambient           = {ctx.ambient_color.x, ctx.ambient_color.y, ctx.ambient_color.z},
        diffuse           = {ctx.diffuse_color.x, ctx.diffuse_color.y, ctx.diffuse_color.z},
        // Fog parameters
        camera_pos        = {ctx.camera_pos.x, ctx.camera_pos.y, ctx.camera_pos.z},
        fog_enabled       = ctx.fog_enabled ? 1 : 0,
        fog_color         = {ctx.fog_color.x, ctx.fog_color.y, ctx.fog_color.z},
        fog_start         = ctx.fog_start,
        fog_end           = ctx.fog_end,
        height_factor     = ctx.height_factor,
        // Rendering component toggles
        texture_enabled   = ctx.texture_enabled ? 1 : 0,
        tile_color_enabled = ctx.tile_color_enabled ? 1 : 0,
        ambient_enabled   = ctx.ambient_enabled ? 1 : 0,
        shadowmap_enabled = ctx.shadowmap_enabled ? 1 : 0,
        colormap_enabled  = ctx.colormap_enabled ? 1 : 0,
        lighting_enabled  = ctx.lighting_enabled ? 1 : 0,
        lightmap_posterize = ctx.lightmap_posterize ? 1 : 0,
        // Directional light parameters
        light_dir         = {ctx.light_dir.x, ctx.light_dir.y, ctx.light_dir.z},
    }
    vk.CmdPushConstants(cmd, ctx.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(Push_Constants), &push)

    // Draw mesh
    vk.CmdDraw(cmd, ctx.vertex_count, 1, 0, 0)

    // Reset polygon mode to FILL for UI (don't render UI as wireframe)
    vk.CmdSetPolygonModeEXT(cmd, .FILL)

    // Render UI overlay
    ui_render(ctx, cmd)

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

    present_result := vk.QueuePresentKHR(ctx.present_queue, &present_info)

    if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || ctx.framebuffer_resized {
        ctx.framebuffer_resized = false
        recreate_swapchain(ctx)
    }

    ctx.current_frame = (frame + 1) % MAX_FRAMES_IN_FLIGHT
}
