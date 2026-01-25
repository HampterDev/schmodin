package main

import vk "vendor:vulkan"
import "vendor:glfw"

// Constants
WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720
MAX_FRAMES_IN_FLIGHT :: 2
MAX_BINDLESS_RESOURCES :: 16384

// Main application context
Context :: struct {
    window:                  glfw.WindowHandle,
    instance:                vk.Instance,
    debug_messenger:         vk.DebugUtilsMessengerEXT,
    surface:                 vk.SurfaceKHR,
    physical_device:         vk.PhysicalDevice,
    device:                  vk.Device,
    graphics_queue:          vk.Queue,
    present_queue:           vk.Queue,
    graphics_family:         u32,
    present_family:          u32,

    // Swapchain
    swapchain:               vk.SwapchainKHR,
    swapchain_images:        []vk.Image,
    swapchain_views:         []vk.ImageView,
    swapchain_format:        vk.Format,
    swapchain_extent:        vk.Extent2D,

    // Depth buffer
    depth_image:             vk.Image,
    depth_memory:            vk.DeviceMemory,
    depth_view:              vk.ImageView,
    depth_format:            vk.Format,

    // Pipeline layout (still needed for push constants/descriptors)
    pipeline_layout:         vk.PipelineLayout,

    // Shader objects (replaces VkPipeline)
    vertex_shader:           vk.ShaderEXT,
    fragment_shader:         vk.ShaderEXT,

    // Descriptor buffer (replaces descriptor pools/sets)
    bindless_layout:              vk.DescriptorSetLayout,
    descriptor_buffer:            vk.Buffer,
    descriptor_buffer_memory:     vk.DeviceMemory,
    descriptor_buffer_address:    vk.DeviceAddress,
    descriptor_buffer_size:       vk.DeviceSize,

    // Command resources
    command_pool:            vk.CommandPool,
    command_buffers:         [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,

    // Sync primitives (per-swapchain-image for render_finished to avoid reuse issues)
    image_available:         [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    render_finished:         []vk.Semaphore,  // One per swapchain image
    in_flight_fences:        [MAX_FRAMES_IN_FLIGHT]vk.Fence,
    current_frame:           u32,

    // Buffer device address
    vertex_buffer:           vk.Buffer,
    vertex_memory:           vk.DeviceMemory,
    vertex_buffer_address:   vk.DeviceAddress,
}

// Push constants - matches shader layout
Push_Constants :: struct {
    vertices:      vk.DeviceAddress,  // Buffer device address (8 bytes)
    texture_index: u32,
    _padding:      u32,
}

// Vertex data
Vertex :: struct {
    pos:   [3]f32,
    color: [3]f32,
    uv:    [2]f32,
}

// Required layers and extensions
VALIDATION_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"}

// Extensions beyond Vulkan 1.3 core
// (dynamic_rendering, synchronization2, buffer_device_address, descriptor_indexing,
//  maintenance3, extended_dynamic_state are all core in 1.2/1.3)
DEVICE_EXTENSIONS := [?]cstring{
    vk.KHR_SWAPCHAIN_EXTENSION_NAME,                    // Required for presenting
    vk.EXT_EXTENDED_DYNAMIC_STATE_2_EXTENSION_NAME,     // More dynamic state
    vk.EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME,     // Even more dynamic state
    vk.EXT_SHADER_OBJECT_EXTENSION_NAME,                // No VkPipeline needed
    vk.EXT_VERTEX_INPUT_DYNAMIC_STATE_EXTENSION_NAME,   // Dynamic vertex input
    vk.EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME,            // No descriptor pools/sets
}
