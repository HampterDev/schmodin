#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

// Vertex struct - must match Odin Vertex struct
struct Vertex {
    vec3 pos;
    vec3 normal;     // Surface normal for directional lighting
    vec3 color;
    vec2 uv;
    vec2 lm_uv;      // Lightmap UV coordinates
    uint tex_index;
    uint _padding;
};

// Vertex buffer accessed via buffer device address
layout(buffer_reference, scalar) readonly buffer VertexBuffer {
    Vertex v[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;                   // Model-View-Projection matrix (64 bytes)
    VertexBuffer vertices;      // Buffer device address (8 bytes)
    uint texture_index;
    uint _pad0;
    vec3 ambient;
    float _pad1;
    vec3 diffuse;
    float _pad2;
    // Fog parameters
    vec3 camera_pos;
    uint fog_enabled;
    vec3 fog_color;
    float fog_start;
    float fog_end;
    float height_factor;
    // Rendering component toggles
    uint texture_enabled;
    uint tile_color_enabled;
    uint ambient_enabled;
    uint shadowmap_enabled;
    uint colormap_enabled;
    uint lighting_enabled;
    uint lightmap_posterize;
    uint _pad_toggle;
    // Directional light parameters
    vec3 light_dir;
    float _pad3;
} pc;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec2 frag_uv;
layout(location = 2) out vec2 frag_lm_uv;
layout(location = 3) flat out uint frag_texture_index;
layout(location = 4) out vec3 frag_world_pos;
layout(location = 5) out vec3 frag_normal;

void main() {
    Vertex vtx = pc.vertices.v[gl_VertexIndex];

    // Apply height factor (0=flat, 1=normal)
    vec3 pos = vtx.pos;
    pos.y *= pc.height_factor;

    gl_Position = pc.mvp * vec4(pos, 1.0);
    frag_color = vtx.color;
    frag_uv = vtx.uv;
    frag_lm_uv = vtx.lm_uv;
    frag_texture_index = vtx.tex_index;
    frag_world_pos = pos;  // Pass world position for range-based fog
    frag_normal = vtx.normal;  // Pass normal for directional lighting
}
