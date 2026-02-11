#version 460
#extension GL_EXT_nonuniform_qualifier : require

// Bindless texture array for diffuse textures
layout(set = 0, binding = 0) uniform sampler2D textures[];

// Map atlas textures (pre-computed lighting data)
layout(set = 1, binding = 0) uniform sampler2D shadow_atlas;       // Lightmap intensity
layout(set = 2, binding = 0) uniform sampler2D light_atlas;        // Lightmap specular RGB
layout(set = 3, binding = 0) uniform sampler2D lighting_atlas;     // Pre-computed N·L
layout(set = 4, binding = 0) uniform sampler2D half_lambert_atlas; // Pre-computed Half-Lambert

// Push constants (must match vertex shader and Odin Push_Constants layout)
layout(push_constant) uniform PushConstants {
    mat4 mvp;                   // offset 0, 64 bytes
    uvec2 vertices;             // offset 64, 8 bytes (buffer address as 2x uint)
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

// Inputs from vertex shader
layout(location = 0) in vec3 frag_color;
layout(location = 1) in vec2 frag_uv;
layout(location = 2) in vec2 frag_lm_uv;
layout(location = 3) flat in uint frag_texture_index;
layout(location = 4) in vec3 frag_world_pos;
layout(location = 5) in float frag_prelit;

// Output
layout(location = 0) out vec4 out_color;

void main() {
    // Sample diffuse texture (or use white if disabled)
    vec4 diffuse;
    if (pc.texture_enabled != 0) {
        diffuse = texture(textures[nonuniformEXT(frag_texture_index)], frag_uv);
    } else {
        diffuse = vec4(1.0);
    }

    // Build multiplicative base: texture × tileColor × lighting
    vec3 base = diffuse.rgb;

    // Apply tile/vertex color
    if (pc.tile_color_enabled != 0) {
        // Quantize to 8-bit to simulate D3D7 integer interpolation
        vec3 vertColor = floor(frag_color * 255.0 + 0.5) / 255.0;
        base *= vertColor;
    }

    // Apply pre-computed lighting (per-vertex or from atlas)
    if (pc.prelit_enabled != 0) {
        // Per-vertex pre-computed lighting (covers all triangles including walls)
        base *= frag_prelit;
    } else if (pc.half_lambert_enabled != 0) {
        // Half-Lambert from atlas: softer, wrapping lighting (top surfaces only)
        float half_lambert = texture(half_lambert_atlas, frag_lm_uv).r;
        base *= half_lambert;
    } else if (pc.lighting_enabled != 0) {
        // Standard N·L from atlas (top surfaces only)
        float lighting = texture(lighting_atlas, frag_lm_uv).r;
        base *= lighting;
    }

    // Sample shadow (lightmap intensity) - defaults to 1.0 if disabled
    float shadow = 1.0;
    if (pc.shadow_enabled != 0) {
        shadow = texture(shadow_atlas, frag_lm_uv).r;
    }

    // Sample light (lightmap specular RGB) - defaults to 0.0 if disabled
    vec3 light = vec3(0.0);
    if (pc.light_enabled != 0) {
        light = texture(light_atlas, frag_lm_uv).rgb;
    }

    // D3D7 formula: light + shadow × base
    // D3DTOP_MODULATEALPHA_ADDCOLOR: Arg1.RGB + Arg1.A × Arg2.RGB
    vec3 result = light + shadow * base;

    // Apply range-based linear fog (D3DFOG_LINEAR with RANGEFOGENABLE)
    if (pc.fog_enabled != 0) {
        // Range-based fog uses actual 3D distance from camera, not just Z depth
        float dist = distance(frag_world_pos, pc.camera_pos);

        // Linear fog formula: fog_factor = (end - dist) / (end - start)
        // fog_factor = 1.0 means no fog (100% scene color)
        // fog_factor = 0.0 means full fog (100% fog color)
        float fog_factor = clamp((pc.fog_end - dist) / (pc.fog_end - pc.fog_start), 0.0, 1.0);

        // Blend: final = mix(fog_color, scene_color, fog_factor)
        result = mix(pc.fog_color, result, fog_factor);
    }

    out_color = vec4(result, diffuse.a);
}
