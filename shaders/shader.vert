#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

// Vertex struct
struct Vertex {
    vec3 pos;
    vec3 color;
    vec2 uv;
};

// Vertex buffer accessed via buffer device address
layout(buffer_reference, scalar) readonly buffer VertexBuffer {
    Vertex v[];
};

layout(push_constant) uniform PushConstants {
    VertexBuffer vertices;  // Buffer device address (8 bytes)
    uint texture_index;
    uint _padding;
} pc;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec2 frag_uv;
layout(location = 2) flat out uint frag_texture_index;

void main() {
    Vertex vtx = pc.vertices.v[gl_VertexIndex];

    gl_Position = vec4(vtx.pos, 1.0);
    frag_color = vtx.color;
    frag_uv = vtx.uv;
    frag_texture_index = pc.texture_index;
}
