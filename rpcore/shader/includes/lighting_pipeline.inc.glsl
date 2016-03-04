/**
 *
 * RenderPipeline
 *
 * Copyright (c) 2014-2016 tobspr <tobias.springer1@gmail.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#pragma once

#pragma include "includes/material.struct.glsl"
#pragma include "includes/light_culling.inc.glsl"
#pragma include "includes/lights.inc.glsl"
#pragma include "includes/light_data.inc.glsl"
#pragma include "includes/shadows.inc.glsl"
#pragma include "includes/noise.inc.glsl"
#pragma include "includes/light_classification.inc.glsl"
#pragma include "includes/poisson_disk.inc.glsl"

uniform isampler2DArray CellIndices;
uniform isamplerBuffer PerCellLights;
uniform samplerBuffer AllLightsData;
uniform samplerBuffer ShadowSourceData;

uniform sampler2D ShadowAtlas;

#if SUPPORT_PCF
uniform sampler2DShadow ShadowAtlasPCF;
#endif


// Use ambient occlusion data, but only if we work in scren space, and only if
// the plugin is enabled
#if IS_SCREEN_SPACE && HAVE_PLUGIN(ao)
    uniform sampler2D AmbientOcclusion;
#endif

int get_pointlight_source_offs(vec3 direction) {
    vec3 abs_dir = abs(direction);
    float max_comp = max(abs_dir.x, max(abs_dir.y, abs_dir.z));
    // TODO: Use step(x, 0) + 1 instead of y > 0 ? 0 : 1
    if (abs_dir.x >= max_comp) return direction.x >= 0.0 ? 0 : 1;
    if (abs_dir.y >= max_comp) return direction.y >= 0.0 ? 2 : 3;
    return direction.z >= 0.0 ? 4 : 5;
}

// Processes a spot light
vec3 process_spotlight(Material m, LightData light_data, vec3 view_vector, vec4 directional_occlusion, float shadow_factor) {
    const vec3 transmittance = vec3(1); // <-- TODO

    // Get the lights data
    int ies_profile = get_ies_profile(light_data);
    vec3 position   = get_light_position(light_data);
    float radius    = get_spotlight_radius(light_data);
    float fov       = get_spotlight_fov(light_data);
    vec3 direction  = get_spotlight_direction(light_data);
    vec3 l          = position - m.position;
    vec3 l_norm     = normalize(l);

    // Compute the spot lights attenuation
    float attenuation = get_spotlight_attenuation(l_norm, direction, fov, radius,
                                                  dot(l, l), ies_profile);

    // Compute the lights influence
    return apply_light(m, view_vector, l, get_light_color(light_data), attenuation,
                       shadow_factor, directional_occlusion, transmittance);
}

// Processes a point light
vec3 process_pointlight(Material m, LightData light_data, vec3 view_vector, vec4 directional_occlusion, float shadow_factor) {
    const vec3 transmittance = vec3(1); // <-- TODO

    // Get the lights data
    float radius    = get_pointlight_radius(light_data);
    vec3 position   = get_light_position(light_data);
    int ies_profile = get_ies_profile(light_data);
    vec3 l          = position - m.position;
    vec3 l_norm     = normalize(l);

    // Get the point light attenuation
    // float attenuation = get_pointlight_attenuation(l_norm, radius, dot(l, l), ies_profile);
    float attenuation = get_pointlight_attenuation(l_norm, radius, dot(l, l), ies_profile);

    // Compute the lights influence
    return apply_light(m, view_vector, l, get_light_color(light_data),
                       attenuation, shadow_factor, directional_occlusion, transmittance);
}

// Filters a shadow map
float filter_shadowmap(Material m, SourceData source, vec3 l) {

    // TODO: Examine if this is faster
    if (dot(m.normal, -l) < 0) return 0.0;

    mat4 mvp = get_source_mvp(source);
    vec4 uv = get_source_uv(source);

    // TODO: make this configurable
    const float slope_bias = 0.00;
    const float normal_bias = 0.03;
    const float const_bias = 0.001;
    vec3 biased_pos = get_biased_position(m.position, slope_bias, normal_bias, m.normal, l);
    vec3 projected = project(mvp, biased_pos);
    vec2 projected_coord = projected.xy * uv.zw + uv.xy;

    const int num_samples = 12;
    const float filter_size = 2.0 / SHADOW_ATLAS_SIZE; // TODO: Use shadow atlas size

    float accum = 0.0;

    vec3 rand_offs = rand_rgb(m.position.xy + m.position.z) * 2 - 1;
    rand_offs *= 0.15;

    for (int i = 0; i < num_samples; ++i) {
        vec2 offs = projected_coord.xy + poisson_disk_2D_12[i] * filter_size + rand_offs.xy * filter_size;
        #if SUPPORT_PCF
        accum += textureLod(ShadowAtlasPCF, vec3(offs, projected.z - const_bias), 0).x;
        #else
        accum += step(textureProj(ShadowAtlas, vec3(offs, projected.z - const_bias), 0).x, projected.z - const_bias);
        #endif
    }

    return accum / num_samples;
}



// Shades the material from the per cell light buffer
vec3 shade_material_from_tile_buffer(Material m, ivec3 tile) {

    #if DEBUG_MODE
        return vec3(0);
    #endif

    vec3 shading_result = vec3(0);

    // Find per tile lights
    int cell_index = texelFetch(CellIndices, tile, 0).x;
    int data_offs = cell_index * (LC_MAX_LIGHTS_PER_CELL + LIGHT_CLS_COUNT);

    // Get directional occlusion
    vec4 directional_occlusion = vec4(0);
    #if IS_SCREEN_SPACE && HAVE_PLUGIN(ao)
        ivec2 coord = ivec2(gl_FragCoord.xy);
        directional_occlusion = normalize(texelFetch(AmbientOcclusion, coord, 0) * 2.0 - 1.0);
        // directional_occlusion.xyz = m.normal;
    #endif

    // Compute view vector
    vec3 v = normalize(MainSceneData.camera_pos - m.position);

    int curr_offs = data_offs + LIGHT_CLS_COUNT;

    // Get the light counts
    int num_spot_noshadow = texelFetch(PerCellLights, data_offs + LIGHT_CLS_SPOT_NOSHADOW).x;
    int num_spot_shadow = texelFetch(PerCellLights, data_offs + LIGHT_CLS_SPOT_SHADOW).x;
    int num_point_noshadow = texelFetch(PerCellLights, data_offs + LIGHT_CLS_POINT_NOSHADOW).x;
    int num_point_shadow = texelFetch(PerCellLights, data_offs + LIGHT_CLS_POINT_SHADOW).x;

    // Debug mode, show tile bounds
    #if 0
        // Show tiles
        #if IS_SCREEN_SPACE
            if (int(gl_FragCoord.x) % LC_TILE_SIZE_X == 0 || int(gl_FragCoord.y) % LC_TILE_SIZE_Y == 0) {
                shading_result += 0.01;
            }
            int num_lights = num_spot_noshadow + num_spot_shadow + num_point_noshadow + num_point_shadow;
            // float light_factor = num_lights / float(LC_MAX_LIGHTS_PER_CELL);
            float light_factor = num_lights / 5.0;
            // shading_result += ( (tile.z + 1) % 2) * 0.01;
            shading_result += light_factor;
        #endif
    #endif

    // Spotlights without shadow
    for (int i = 0; i < num_spot_noshadow; ++i) {
        int light_offs = texelFetch(PerCellLights, curr_offs++).x * 4;
        LightData light_data = read_light_data(AllLightsData, light_offs);
        shading_result += process_spotlight(m, light_data, v, directional_occlusion, 1.0);
    }

    // Spotlights with shadow
    for (int i = 0; i < num_spot_shadow; ++i) {
        int light_offs = texelFetch(PerCellLights, curr_offs++).x * 4;
        LightData light_data = read_light_data(AllLightsData, light_offs);

        // Get shadow factor
        vec3 v2l = normalize(m.position - get_light_position(light_data));
        int source_index = get_shadow_source_index(light_data);
        SourceData source_data = read_source_data(ShadowSourceData, source_index * 5);
        float shadow_factor = filter_shadowmap(m, source_data, v2l);
        shading_result += process_spotlight(m, light_data, v, directional_occlusion, shadow_factor);
    }

    // Pointlights without shadow
    for (int i = 0; i < num_point_noshadow; ++i) {
        int light_offs = texelFetch(PerCellLights, curr_offs++).x * 4;
        LightData light_data = read_light_data(AllLightsData, light_offs);
        shading_result += process_pointlight(m, light_data, v, directional_occlusion, 1.0);
    }

    // Pointlights with shadow
    for (int i = 0; i < num_point_shadow; ++i) {
        int light_offs = texelFetch(PerCellLights, curr_offs++).x * 4;
        LightData light_data = read_light_data(AllLightsData, light_offs);

        // Get shadow factor
        int source_index = get_shadow_source_index(light_data);
        vec3 v2l = normalize(m.position - get_light_position(light_data));
        source_index += get_pointlight_source_offs(v2l);

        SourceData source_data = read_source_data(ShadowSourceData, source_index * 5);
        float shadow_factor = filter_shadowmap(m, source_data, v2l);
        shading_result += process_pointlight(m, light_data, v, directional_occlusion, shadow_factor);
    }

    return shading_result;
}
