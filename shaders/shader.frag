#version 460
#extension GL_EXT_nonuniform_qualifier : require

// Bindless texture array
layout(set = 0, binding = 0) uniform sampler2D textures[];

// Push constants (must match vertex shader)
layout(push_constant) uniform PushConstants {
    uint texture_index;
    uint _padding0;
    uint _padding1;
    uint _padding2;
} pc;

// Inputs from vertex shader
layout(location = 0) in vec3 frag_color;
layout(location = 1) in vec2 frag_uv;
layout(location = 2) flat in uint frag_texture_index;

// Output
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(frag_color, 1.0);
}
