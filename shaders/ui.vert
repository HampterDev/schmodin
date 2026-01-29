#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

// UI Vertex struct for microui
struct UIVertex {
    vec2 pos;
    vec2 uv;
    uint color;  // RGBA packed
};

// Vertex buffer accessed via buffer device address
layout(buffer_reference, scalar) readonly buffer UIVertexBuffer {
    UIVertex v[];
};

layout(push_constant) uniform PushConstants {
    UIVertexBuffer vertices;
    vec2 screen_size;
} pc;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

void main() {
    UIVertex vtx = pc.vertices.v[gl_VertexIndex];

    // Convert from screen coords to NDC (-1 to 1)
    vec2 pos = vtx.pos / pc.screen_size * 2.0 - 1.0;
    gl_Position = vec4(pos.x, pos.y, 0.0, 1.0);

    frag_uv = vtx.uv;

    // Unpack color from u32 (RGBA)
    frag_color = vec4(
        float((vtx.color >> 0) & 0xFF) / 255.0,
        float((vtx.color >> 8) & 0xFF) / 255.0,
        float((vtx.color >> 16) & 0xFF) / 255.0,
        float((vtx.color >> 24) & 0xFF) / 255.0
    );
}
