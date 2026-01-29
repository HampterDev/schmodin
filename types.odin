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

    // Lightmap descriptor set (set 1)
    lightmap_layout:                  vk.DescriptorSetLayout,
    lightmap_descriptor_buffer:       vk.Buffer,
    lightmap_descriptor_buffer_memory: vk.DeviceMemory,
    lightmap_descriptor_buffer_address: vk.DeviceAddress,
    lightmap_descriptor_buffer_size:  vk.DeviceSize,

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
    vertex_count:            u32,

    // Textures
    textures:                []Texture,
    sampler:                 vk.Sampler,
    lightmap_atlas:          Texture,      // Combined lightmap atlas
    lightmap_sampler:        vk.Sampler,   // Separate sampler for lightmaps

    // Framebuffer resize tracking
    framebuffer_resized:     bool,
    vulkan_initialized:      bool,  // Guard for resize callback

    // Fullscreen state
    is_fullscreen:           bool,
    start_fullscreen:        bool,     // Deferred fullscreen toggle (after Vulkan init)
    windowed_pos:            [2]i32,   // Stored position when entering fullscreen
    windowed_size:           [2]i32,   // Stored size when entering fullscreen

    // Camera state
    camera_pos:              Vec3,
    camera_rot:              Quat,  // Quaternion rotation

    // Mouse state for camera control
    last_mouse_x:            f64,
    last_mouse_y:            f64,
    mouse_captured:          bool,
    scroll_delta:            f32,  // Accumulated scroll for this frame

    // Rendering toggles
    f_key_was_pressed:       bool,  // For fog toggle edge detection
    polygon_mode:            u32,   // 0=FILL, 1=LINE, 2=POINT
    v_key_was_pressed:       bool,  // For polygon mode toggle
    f11_key_was_pressed:     bool,  // For fullscreen toggle
    height_factor:           f32,   // 0=flat, 1=normal height (UI slider)

    // Rendering component toggles
    texture_enabled:         bool,  // Ground texture
    tile_color_enabled:      bool,  // Tile/vertex colors from GND surface
    ambient_enabled:         bool,  // Ambient light addition
    shadowmap_enabled:       bool,  // Lightmap shadow/intensity channel (alpha)
    colormap_enabled:        bool,  // Lightmap color channel (RGB)
    lighting_enabled:        bool,  // Directional lighting (N·L)
    lightmap_posterize:      bool,  // Posterize lightmap (4-bit per channel like D3D7)

    // Lighting from RSW
    ambient_color:           Vec3,
    diffuse_color:           Vec3,
    envdiff:                 Vec3,  // 1 - (1-diffuse)*(1-ambient)
    light_dir:               Vec3,  // Normalized light direction
    shadow_opacity:          f32,   // Light opacity/intensity multiplier

    // Fog parameters (from D3D trace)
    fog_enabled:             bool,
    fog_color:               Vec3,  // RGB (4, 12, 154) / 255
    fog_start:               f32,   // 161.468
    fog_end:                 f32,   // 1416.0

    // Map selection
    available_maps:          []string,  // List of RSW files from GRF
    current_map_index:       int,       // Currently selected map index
    current_map_name:        string,    // Currently loaded map name
    map_needs_reload:        bool,      // Flag to trigger map reload

    // UI resources (microui)
    ui_vertex_buffer:        vk.Buffer,
    ui_vertex_memory:        vk.DeviceMemory,
    ui_vertex_buffer_address: vk.DeviceAddress,
    ui_index_buffer:         vk.Buffer,
    ui_index_memory:         vk.DeviceMemory,
    ui_atlas_texture:        Texture,
    ui_vertex_shader:        vk.ShaderEXT,
    ui_fragment_shader:      vk.ShaderEXT,
    ui_pipeline_layout:      vk.PipelineLayout,
    ui_descriptor_layout:    vk.DescriptorSetLayout,
    ui_descriptor_buffer:    vk.Buffer,
    ui_descriptor_buffer_memory: vk.DeviceMemory,
    ui_descriptor_buffer_address: vk.DeviceAddress,
    ui_descriptor_buffer_size: vk.DeviceSize,
}

// 4x4 Matrix (column-major for Vulkan/GLSL)
Mat4 :: [4][4]f32

// Push constants - matches shader layout
Push_Constants :: struct {
    mvp:               Mat4,              // Model-View-Projection matrix (64 bytes)
    vertices:          vk.DeviceAddress,  // Buffer device address (8 bytes)
    texture_index:     u32,
    _pad0:             u32,
    ambient:           [3]f32,            // RSW ambient color (0-1)
    _pad1:             f32,
    diffuse:           [3]f32,            // RSW diffuse color (0-1)
    _pad2:             f32,
    // Fog parameters (range-based linear fog)
    camera_pos:        [3]f32,            // Camera position for range-based fog
    fog_enabled:       u32,               // 1 = enabled, 0 = disabled
    fog_color:         [3]f32,            // Fog color RGB (0-1)
    fog_start:         f32,               // Fog start distance (161.468)
    fog_end:           f32,               // Fog end distance (1416.0)
    height_factor:     f32,               // 0=flat, 1=normal height
    // Rendering component toggles
    texture_enabled:   u32,               // 1 = sample texture, 0 = white
    tile_color_enabled: u32,              // 1 = use tile/vertex colors, 0 = white
    ambient_enabled:   u32,               // 1 = add ambient, 0 = skip
    shadowmap_enabled: u32,               // 1 = use lightmap alpha (shadow), 0 = skip
    colormap_enabled:  u32,               // 1 = use lightmap RGB (color), 0 = skip
    lighting_enabled:  u32,               // 1 = directional lighting (N·L), 0 = skip
    lightmap_posterize: u32,              // 1 = posterize lightmap (4-bit), 0 = smooth
    _pad_toggle:       u32,               // Padding for alignment
    // Directional light parameters
    light_dir:         [3]f32,            // Normalized light direction (from RSW)
    _pad3:             f32,               // Padding
}

// Vertex data
Vertex :: struct {
    pos:        [3]f32,
    normal:     [3]f32,  // Surface normal for directional lighting
    color:      [3]f32,
    uv:         [2]f32,
    lm_uv:      [2]f32,  // Lightmap UV coordinates
    tex_index:  u32,     // Texture index for bindless texturing
    _padding:   u32,     // Padding for alignment
}

// Texture resource
Texture :: struct {
    image:      vk.Image,
    memory:     vk.DeviceMemory,
    view:       vk.ImageView,
    width:      u32,
    height:     u32,
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
