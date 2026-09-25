// -----------------------------------------------------------------------------
// This file is part of RetroVisor
//
// Copyright (C) Dirk W. Hoffmann. www.dirkwhoffmann.de
// Licensed under the GNU General Public License v3
//
// See https://www.gnu.org for license information
// -----------------------------------------------------------------------------

// #include <metal_stdlib>

#include "MathToolbox.metal"
#include "ColorToolbox.metal"

using namespace metal;

struct VertexIn {

    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {

    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {

    float time;
    float2 shift;
    float zoom;
    float intensity;
    float2 resolution;
    float2 window;
    float2 center;
    float2 mouse;
    uint resample;
    float resampleX;
    float resampleY;
    uint debug;
    uint debugMode;
    float3 debugColor;
    float2 debugXY;
};

//
// Vertex shader
//

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    return out;
}

//
// Fragment shader
//

/* The fragment shader used in the final render stage, where the computed
 * texture is drawn onto a fullscreen quad.
 *
 * Responsibilities:
 *
 *  - Applies an optional zoom effect (magnification feature)
 *  - Applies an optional water-ripple effect (window animation effect)
 *  - Mixes the effect texture with the original texture (in debug mode)
 *  - Draws the final texture onto a fullscreen quad
 */

inline float2 debugWeight(float2 uv, constant Uniforms &u) {
    
    constexpr float2 signs[4] = {
        
        float2( 1.0,  1.0), // Upper left
        float2(-1.0,  1.0), // Upper right
        float2( 1.0, -1.0), // Lower left
        float2(-1.0, -1.0)  // Lower right
    };
    
    float2 s = signs[(u.debug - 1) & 3];
    float2 xy = select(u.debugXY, 1.0 - u.debugXY, s < 0);
    return s * (uv - xy);
}

inline float4 sampleFragment(float2 uv,
                             texture2d<float> orig,
                             texture2d<float> tex,
                             constant Uniforms& uniforms,
                             sampler sam) {
    
    if (uniforms.debug == 0) {
        
        return tex.sample(sam, uv);
        
    } else {
        
        float2 w = debugWeight(uv, uniforms);
        bool inside = w.x < 0 && w.y < 0;
        bool border = false; // inside && (abs(w.x) < 0.002 || abs(w.y) < 0.002);
        
        // Border pixels
        if (border) { return float4(uniforms.debugColor, 1.0); }
        
        // Pixels from the input texture
        if (!inside) { return orig.sample(sam, uv); }
        
        // Pixels from the effect texture
        if (uniforms.debugMode == 0) { return tex.sample(sam, uv); }
        
        // Diff modes
        float4 source = orig.sample(sam, uv);
        float4 effect = tex.sample(sam, uv);
        // float4 diff = 0.5 * (effect - source);
        float4 diff = abs(effect - source);
        float3 offset = 0.0;
        
        switch (uniforms.debugMode) {
                
            case 1: return float4(diff.rgb + offset, 1.0);
            case 2: return float4(diff.rrr + offset, 1.0);
            case 3: return float4(diff.ggg + offset, 1.0);
            case 4: return float4(diff.bbb + offset, 1.0);
            default: return float4(float3(LUM(Color4(diff))), 1.0);
        }
    }
}
    
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> orig [[texture(0)]],
                              texture2d<float> tex [[texture(1)]],
                              constant Uniforms& uniforms [[buffer(0)]],
                              sampler sam [[sampler(0)]]) {

    // Scale and shift coordinate according to the given zoom and parameters
    float2 uv = in.texCoord / uniforms.zoom + uniforms.shift;
    float2 mouse = uniforms.mouse / uniforms.zoom + uniforms.shift;
    
    // Apply the water-ripple effect if enabled
    if (uniforms.intensity > 0.0) {
        
        // Ripple parameters
        float waveFreq        = 100.0;
        float waveSpeed       = 10.0;
        float baseAmp         = 0.025 * uniforms.intensity;
        float brightnessDepth = 0.15 * uniforms.intensity;
        float frequencyDrop   = 0.75;
        
        // Compute distance to the center
        float2 dir = uv - mouse;
        float dist = length(dir);
        
        // Make wavelength increase with distance
        float variableFreq = waveFreq / (1.0 + dist * frequencyDrop);
        
        // Lower the amplitude with distance
        float ampFalloff = exp(-dist * 0.5);
        float rippleAmp = baseAmp * ampFalloff;
        
        // Simulate ripple and displacement
        float ripple = sin((dist * variableFreq) - (uniforms.time * waveSpeed));
        float offset = ripple * rippleAmp;
        float2 rippleUV = uv + (dist > 0.0001 ? normalize(dir) * offset : float2(0.0));
        
        // Rectify the coordinates at the border
        rippleUV = clamp(rippleUV, float2(0.01), float2(0.99));
        
        // float4 color = tex.sample(sam, rippleUV);
        float4 color = sampleFragment(rippleUV, orig, tex, uniforms, sam);
        float brightness = 1.0 - brightnessDepth * (cos((dist * variableFreq) - (uniforms.time * waveSpeed)) * 0.5 + 0.5);
        color.rgb *= brightness;
        
        return color;
    }

    return sampleFragment(uv, orig, tex, uniforms, sam);
}

//
// Dot mask kernel (Used by DotMasLibrary)
//

struct DotMaskdUniforms {
    
    uint WIDTH;
    uint HEIGHT;
    uint TYPE;
    uint COLOR;
    uint SIZE;
    float SATURATION;
    float BRIGHTNESS;
    float BLUR;
};

kernel void dotMask(texture2d<half, access::sample> input     [[ texture(0) ]],
                    texture2d<half, access::write>  output    [[ texture(1) ]],
                    constant DotMaskdUniforms       &u        [[ buffer(0)  ]],
                    sampler                         sam       [[ sampler(0) ]],
                    uint2                           gid       [[ thread_position_in_grid ]])
{
    float2 texSize = float2(input.get_width(), input.get_height());
    uint2 gridSize = uint2(float2(u.SIZE, u.SIZE) * texSize);

    float2 uv = (float2(gid % gridSize) + 0.5) / float2(gridSize);

    half4 color = input.sample(sam, uv);
    output.write(color, gid);
}

//
// chicago95 fork: square the window server's rounded bottom corners in the
// captured image. `cut` is the measured macOS 27 window corner: for each
// row counted up from the bottom edge, how many capture pixels at that end
// of the row fall outside the window (alpha < 50%). Pixels there, plus a
// small antialiasing margin, take the nearest pixel inside the window along
// the bottom edge (below the diagonal) or along the side edge (above it),
// so lines that run along the edges continue straight into the corner.
//

constant int cornerCut[35] = { 35, 25, 21, 18, 16, 15, 13, 12, 11, 10, 9, 8, 7, 6, 6, 5, 4,
                               4, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };

struct CornerUniforms {
    float scale;    // texture pixels per capture pixel (1 at 1:1)
    int margin;     // extra pixels replaced past the cut, for the antialiased edge
};

// Pixels at the start of row k (from the bottom) that are outside, in texture pixels
static int cutAt(int k, float scale, int margin) {
    int i = int(float(k) / scale);
    if (i < 0 || i >= 35) return 0;
    return int(ceil(float(cornerCut[i]) * scale)) + margin;
}

kernel void squareCorners(texture2d<float, access::read>  src [[ texture(0) ]],
                          texture2d<float, access::write> dst [[ texture(1) ]],
                          constant CornerUniforms &u        [[ buffer(0) ]],
                          uint2 gid                          [[ thread_position_in_grid ]])
{
    int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    float4 color = src.read(gid);
    int k = h - 1 - int(gid.y);                       // row from the bottom
    bool right = int(gid.x) >= w / 2;
    int x = right ? (w - 1 - int(gid.x)) : int(gid.x); // column from the nearer side

    int span = int(ceil(35.0 * u.scale)) + u.margin;
    if (k < span && x < span) {
        int rowCut = cutAt(k, u.scale, u.margin);
        if (x < rowCut && cutAt(k, u.scale, 0) > 0) {
            int sx, sy;
            if (k <= x) {
                // closer to the bottom edge: first inside pixel along this row
                sx = rowCut; sy = h - 1 - k;
            } else {
                // closer to the side edge: first inside pixel up this column
                int kk = k;
                while (kk < span + 2 && x < cutAt(kk, u.scale, u.margin) && cutAt(kk, u.scale, 0) > 0) kk++;
                sx = x; sy = h - 1 - (kk + u.margin);
            }
            if (right) sx = w - 1 - sx;
            color = src.read(uint2(clamp(sx, 0, w - 1), clamp(sy, 0, h - 1)));
        }
    }
    dst.write(color, gid);
}
