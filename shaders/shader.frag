#version 460
#extension GL_EXT_nonuniform_qualifier : require

// Bindless texture array for diffuse textures
layout(set = 0, binding = 0) uniform sampler2D textures[];

// Lightmap atlas texture (separate from bindless array)
layout(set = 1, binding = 0) uniform sampler2D lightmap_atlas;

// Push constants (must match vertex shader layout)
layout(push_constant) uniform PushConstants {
    mat4 mvp;               // 64 bytes
    uvec2 vertices;         // 8 bytes (buffer address as 2x uint)
    uint texture_index;     // 4 bytes
    uint _pad0;             // 4 bytes
    vec3 ambient;           // 12 bytes - RSW ambient color
    float _pad1;            // 4 bytes
    vec3 diffuse;           // 12 bytes - RSW diffuse color
    float _pad2;            // 4 bytes
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

// Inputs from vertex shader
layout(location = 0) in vec3 frag_color;
layout(location = 1) in vec2 frag_uv;
layout(location = 2) in vec2 frag_lm_uv;
layout(location = 3) flat in uint frag_texture_index;
layout(location = 4) in vec3 frag_world_pos;
layout(location = 5) in vec3 frag_normal;

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

    // Apply tile/vertex color with lighting
    // The tile colors from GND are pre-baked vertex colors
    vec3 vertColor;
    if (pc.tile_color_enabled != 0) {
        // Quantize to 8-bit to simulate D3D7 integer interpolation
        vertColor = floor(frag_color * 255.0 + 0.5) / 255.0;
    } else {
        vertColor = vec3(1.0);
    }

    // Build lighting contribution independently
    // Note: When lightmaps are enabled (shadowmap/colormap), the lighting is already baked in.
    // Only apply dynamic lighting when NOT using lightmaps.
    bool using_lightmaps = (pc.shadowmap_enabled != 0 || pc.colormap_enabled != 0);

    if (!using_lightmaps && (pc.ambient_enabled != 0 || pc.lighting_enabled != 0)) {
        vec3 light_factor = vec3(0.0);

        // Ambient adds flat ambient color
        if (pc.ambient_enabled != 0) {
            light_factor += pc.ambient;
        }

        // Lighting adds N·L directional component (like DHXJ)
        if (pc.lighting_enabled != 0) {
            vec3 normal = normalize(frag_normal);
            float n_dot_l = dot(normal, pc.light_dir);  // Allow negative for testing
            light_factor += n_dot_l * pc.diffuse;
        }

        vertColor *= light_factor;
    }

    // Stage 0: texture * processed vertex color
    vec3 colored = diffuse.rgb * vertColor;

    vec4 final_color;

    // Lightmap blending - shadow map (alpha) and color map (RGB) can be toggled separately
    // D3DTOP_MODULATEALPHA_ADDCOLOR: Arg1.RGB + Arg1.A × Arg2.RGB
    // = lightmap.rgb + lightmap.a * stage0.rgb
    if (pc.shadowmap_enabled != 0 || pc.colormap_enabled != 0) {
        vec4 lightmap = texture(lightmap_atlas, frag_lm_uv);

        // Optional posterization (4-bit per channel = 16 levels, like D3D7 ARGB4444)
        if (pc.lightmap_posterize != 0) {
            lightmap = floor(lightmap * 16.0) / 16.0;
        }

        // Shadow map is stored in alpha channel (ambient occlusion)
        float shadow = (pc.shadowmap_enabled != 0) ? lightmap.a : 1.0;

        // Color lightmap is stored in RGB channels (prebaked lighting colors)
        vec3 lm_color = (pc.colormap_enabled != 0) ? lightmap.rgb : vec3(0.0);

        final_color.rgb = lm_color + shadow * colored;
        final_color.a = diffuse.a;
    } else {
        final_color = vec4(colored, diffuse.a);
    }

    // Apply range-based linear fog (D3DFOG_LINEAR with RANGEFOGENABLE)
    if (pc.fog_enabled != 0) {
        // Range-based fog uses actual 3D distance from camera, not just Z depth
        float dist = distance(frag_world_pos, pc.camera_pos);

        // Linear fog formula: fog_factor = (end - dist) / (end - start)
        // fog_factor = 1.0 means no fog (100% scene color)
        // fog_factor = 0.0 means full fog (100% fog color)
        float fog_factor = clamp((pc.fog_end - dist) / (pc.fog_end - pc.fog_start), 0.0, 1.0);

        // Blend: final = mix(fog_color, scene_color, fog_factor)
        final_color.rgb = mix(pc.fog_color, final_color.rgb, fog_factor);
    }

    out_color = final_color;
}
