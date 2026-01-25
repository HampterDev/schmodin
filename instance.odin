package main

import "base:runtime"
import "core:fmt"
import vk "vendor:vulkan"
import "vendor:glfw"

create_instance :: proc(ctx: ^Context) -> bool {
    app_info := vk.ApplicationInfo{
        sType              = .APPLICATION_INFO,
        pApplicationName   = "Modern Vulkan",
        applicationVersion = vk.MAKE_VERSION(1, 0, 0),
        pEngineName        = "No Engine",
        engineVersion      = vk.MAKE_VERSION(1, 0, 0),
        apiVersion         = vk.API_VERSION_1_3,
    }

    glfw_extensions := glfw.GetRequiredInstanceExtensions()
    extensions := make([dynamic]cstring)
    defer delete(extensions)

    for ext in glfw_extensions {
        append(&extensions, ext)
    }
    append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

    create_info := vk.InstanceCreateInfo{
        sType                   = .INSTANCE_CREATE_INFO,
        pApplicationInfo        = &app_info,
        enabledExtensionCount   = u32(len(extensions)),
        ppEnabledExtensionNames = raw_data(extensions),
        enabledLayerCount       = len(VALIDATION_LAYERS),
        ppEnabledLayerNames     = &VALIDATION_LAYERS[0],
    }

    if vk.CreateInstance(&create_info, nil, &ctx.instance) != .SUCCESS {
        return false
    }

    vk.load_proc_addresses_instance(ctx.instance)
    return true
}

debug_callback :: proc "system" (
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: rawptr,
) -> b32 {
    context = runtime.default_context()
    if .ERROR in severity {
        fmt.eprintln("Validation Error:", callback_data.pMessage)
    } else if .WARNING in severity {
        fmt.eprintln("Validation Warning:", callback_data.pMessage)
    }
    return false
}

setup_debug_messenger :: proc(ctx: ^Context) -> bool {
    create_info := vk.DebugUtilsMessengerCreateInfoEXT{
        sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = {.WARNING, .ERROR},
        messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
        pfnUserCallback = debug_callback,
    }

    if vk.CreateDebugUtilsMessengerEXT(ctx.instance, &create_info, nil, &ctx.debug_messenger) != .SUCCESS {
        return false
    }
    return true
}

create_surface :: proc(ctx: ^Context) -> bool {
    return glfw.CreateWindowSurface(ctx.instance, ctx.window, nil, &ctx.surface) == .SUCCESS
}
