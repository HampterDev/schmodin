package main

import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

// Raw shader bytes (will be copied to aligned memory at runtime)
VERT_SPV_RAW := #load("shaders/vert.spv")
FRAG_SPV_RAW := #load("shaders/frag.spv")

create_pipeline :: proc(ctx: ^Context) -> bool {
    log("  Creating pipeline layout...")

    // Push constant range
    push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX, .FRAGMENT},
        offset     = 0,
        size       = size_of(Push_Constants),
    }

    // Pipeline layout with bindless set (set 0) and lightmap set (set 1)
    layouts := [2]vk.DescriptorSetLayout{ctx.bindless_layout, ctx.lightmap_layout}

    layout_info := vk.PipelineLayoutCreateInfo{
        sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount         = 2,
        pSetLayouts            = &layouts[0],
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &push_constant_range,
    }

    if vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.pipeline_layout) != .SUCCESS {
        log("  Pipeline layout creation failed")
        return false
    }
    log("  Pipeline layout created")

    // SPIR-V shaders - copy to aligned memory
    log("  Loading shaders...")
    vert_aligned := make([]u32, (len(VERT_SPV_RAW) + 3) / 4)
    frag_aligned := make([]u32, (len(FRAG_SPV_RAW) + 3) / 4)
    defer delete(vert_aligned)
    defer delete(frag_aligned)

    mem.copy(raw_data(vert_aligned), raw_data(VERT_SPV_RAW), len(VERT_SPV_RAW))
    mem.copy(raw_data(frag_aligned), raw_data(FRAG_SPV_RAW), len(FRAG_SPV_RAW))

    log(fmt.tprintf("  Vert shader size: %d, Frag shader size: %d", len(VERT_SPV_RAW), len(FRAG_SPV_RAW)))

    // Create shader objects (VK_EXT_shader_object) - no VkPipeline needed!
    log("  Creating shader objects...")

    color_format := ctx.swapchain_format

    // Vertex shader create info
    vert_create_info := vk.ShaderCreateInfoEXT{
        sType                  = .SHADER_CREATE_INFO_EXT,
        flags                  = {.LINK_STAGE},
        stage                  = {.VERTEX},
        nextStage              = {.FRAGMENT},
        codeType               = .SPIRV,
        codeSize               = len(VERT_SPV_RAW),
        pCode                  = raw_data(vert_aligned),
        pName                  = "main",
        setLayoutCount         = 2,
        pSetLayouts            = &layouts[0],
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &push_constant_range,
    }

    // Fragment shader create info
    frag_create_info := vk.ShaderCreateInfoEXT{
        sType                  = .SHADER_CREATE_INFO_EXT,
        flags                  = {.LINK_STAGE},
        stage                  = {.FRAGMENT},
        nextStage              = {},
        codeType               = .SPIRV,
        codeSize               = len(FRAG_SPV_RAW),
        pCode                  = raw_data(frag_aligned),
        pName                  = "main",
        setLayoutCount         = 2,
        pSetLayouts            = &layouts[0],
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &push_constant_range,
    }

    // Create linked shaders together
    shader_infos := [2]vk.ShaderCreateInfoEXT{vert_create_info, frag_create_info}
    shaders := [2]vk.ShaderEXT{}

    result := vk.CreateShadersEXT(ctx.device, 2, &shader_infos[0], nil, &shaders[0])
    if result != .SUCCESS {
        log(fmt.tprintf("  CreateShadersEXT failed with: %v", result))
        return false
    }

    ctx.vertex_shader = shaders[0]
    ctx.fragment_shader = shaders[1]

    log("  Shader objects created successfully")
    return true
}
