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

    // Map atlas descriptor buffers (sets 1, 2, 3 for shadow, light, lighting)
    map_atlas_layout:             vk.DescriptorSetLayout,  // Shared layout for all atlas textures
    shadow_descriptor_buffer:     vk.Buffer,
    shadow_descriptor_memory:     vk.DeviceMemory,
    shadow_descriptor_address:    vk.DeviceAddress,
    light_descriptor_buffer:      vk.Buffer,
    light_descriptor_memory:      vk.DeviceMemory,
    light_descriptor_address:     vk.DeviceAddress,
    lighting_descriptor_buffer:   vk.Buffer,
    lighting_descriptor_memory:   vk.DeviceMemory,
    lighting_descriptor_address:  vk.DeviceAddress,
    half_lambert_descriptor_buffer:  vk.Buffer,
    half_lambert_descriptor_memory:  vk.DeviceMemory,
    half_lambert_descriptor_address: vk.DeviceAddress,
    map_descriptor_size:          vk.DeviceSize,  // Size for each atlas descriptor buffer

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

    // Pre-computed map atlases (all use same UV as lightmap)
    shadow_atlas:            Texture,      // Lightmap intensity (grayscale)
    light_atlas:             Texture,      // Lightmap specular RGB
    lighting_atlas:          Texture,      // Pre-computed N·L per cell
    half_lambert_atlas:      Texture,      // Pre-computed Half-Lambert (N·L*0.5+0.5) per cell
    map_sampler:             vk.Sampler,   // Shared sampler for map atlases

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

    // Rendering component toggles (pre-computed maps)
    texture_enabled:         bool,  // Ground texture
    tile_color_enabled:      bool,  // Tile/vertex colors from GND surface
    shadow_enabled:          bool,  // Lightmap shadow/intensity (pre-computed per vertex)
    light_enabled:           bool,  // Lightmap specular RGB (pre-computed per vertex)
    lighting_enabled:        bool,  // N·L directional lighting (pre-computed per vertex)
    half_lambert_enabled:    bool,  // Half-Lambert lighting (N·L*0.5+0.5)
    prelit_enabled:          bool,  // Per-vertex pre-computed lighting (all triangles)

    // Lighting from RSW (used during mesh generation)
    light_dir:               Vec3,  // Normalized light direction
    show_light_indicator:    bool,  // Debug: show sun sphere at light position

    // Debug sun indicator geometry
    sun_vertex_buffer:       vk.Buffer,
    sun_vertex_memory:       vk.DeviceMemory,
    sun_vertex_address:      vk.DeviceAddress,
    sun_vertex_count:        u32,
    map_center:              Vec3,  // Center of current map for sun positioning
    map_radius:              f32,   // Radius to place sun indicator

    // Debug normal arrows geometry
    normal_arrow_buffer:     vk.Buffer,
    normal_arrow_memory:     vk.DeviceMemory,
    normal_arrow_address:    vk.DeviceAddress,
    normal_arrow_count:      u32,   // Number of vertices (2 per arrow = line)
    show_normal_arrows:      bool,  // Toggle for showing normal arrows

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

    // Player marker geometry
    player_marker_buffer:    vk.Buffer,
    player_marker_memory:    vk.DeviceMemory,
    player_marker_address:   vk.DeviceAddress,
    player_marker_count:     u32,

    // Follow camera (Client mode)
    player_pos:              Vec3,    // Authoritative player position (logical + visual offset)
    camera_yaw:              f32,     // Orbit yaw around player (radians)
    camera_pitch:            f32,     // Orbit pitch (radians, clamped)
    camera_distance:         f32,     // Distance from player

    // Networking
    net_mode:    Net_Mode,
    client_net:  Client_Net_State,

    // Walkability grid (extracted from GND)
    walkability:     Walkability_Grid,
    lmb_was_pressed: bool,
}

// 4x4 Matrix (column-major for Vulkan/GLSL)
Mat4 :: [4][4]f32

// Push constants - matches shader layout (std430 alignment for vec3)
// vec3 requires 16-byte alignment in std430, so we add padding
Push_Constants :: struct {
    mvp:                Mat4,              // offset 0, 64 bytes
    vertices:           vk.DeviceAddress,  // offset 64, 8 bytes
    _pad0:              [2]u32,            // offset 72, 8 bytes (align camera_pos to 16)
    camera_pos:         [3]f32,            // offset 80, 12 bytes
    fog_enabled:        u32,               // offset 92, 4 bytes
    fog_color:          [3]f32,            // offset 96, 12 bytes (already 16-aligned)
    fog_start:          f32,               // offset 108, 4 bytes
    fog_end:            f32,               // offset 112, 4 bytes
    height_factor:      f32,               // offset 116, 4 bytes
    texture_enabled:    u32,               // offset 120, 4 bytes
    tile_color_enabled: u32,               // offset 124, 4 bytes
    shadow_enabled:      u32,               // offset 128, 4 bytes
    light_enabled:       u32,               // offset 132, 4 bytes
    lighting_enabled:    u32,               // offset 136, 4 bytes
    half_lambert_enabled: u32,              // offset 140, 4 bytes
    prelit_enabled:      u32,               // offset 144, 4 bytes
}

// Vertex data
Vertex :: struct {
    pos:        [3]f32,
    normal:     [3]f32,  // Surface normal (kept for debugging)
    color:      [3]f32,
    uv:         [2]f32,
    lm_uv:      [2]f32,  // Lightmap/atlas UV coordinates
    tex_index:  u32,     // Texture index for bindless texturing
    prelit:     f32,     // Pre-computed lighting (half-lambert) for all triangles
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
