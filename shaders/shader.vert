#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

// Vertex struct - must match Odin Vertex struct
struct Vertex {
    vec3 pos;
    vec3 normal;
    vec3 color;
    vec2 uv;
    vec2 lm_uv;      // Lightmap/atlas UV coordinates
    uint tex_index;
    float prelit;    // Pre-computed half-lambert lighting for all triangles
};

// Vertex buffer accessed via buffer device address
layout(buffer_reference, scalar) readonly buffer VertexBuffer {
    Vertex v[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;                   // offset 0, 64 bytes
    VertexBuffer vertices;      // offset 64, 8 bytes
    uvec2 _pad0;                // offset 72, 8 bytes (align camera_pos to 16)
    vec3 camera_pos;            // offset 80, 12 bytes
    uint fog_enabled;           // offset 92, 4 bytes
    vec3 fog_color;             // offset 96, 12 bytes
    float fog_start;            // offset 108, 4 bytes
    float fog_end;              // offset 112, 4 bytes
    float height_factor;        // offset 116, 4 bytes
    uint texture_enabled;       // offset 120, 4 bytes
    uint tile_color_enabled;    // offset 124, 4 bytes
    uint shadow_enabled;        // offset 128, 4 bytes
    uint light_enabled;         // offset 132, 4 bytes
    uint lighting_enabled;      // offset 136, 4 bytes
    uint half_lambert_enabled;  // offset 140, 4 bytes
    uint prelit_enabled;        // offset 144, 4 bytes
} pc;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec2 frag_uv;
layout(location = 2) out vec2 frag_lm_uv;
layout(location = 3) flat out uint frag_texture_index;
layout(location = 4) out vec3 frag_world_pos;
layout(location = 5) out float frag_prelit;

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
    frag_prelit = vtx.prelit;  // Pass pre-computed lighting
}
