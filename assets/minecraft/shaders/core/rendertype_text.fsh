#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

// Vanilla 1.21.11 rendertype_text.fsh plus Sol's Radiance's screen effects (see rendertype_text.vsh for
// how an effect is chosen). q is the screen position: centre 0, height -1..1, width scaled by the aspect
// ratio; r = |q|, th = atan(q). The text pipeline has no clock, so every moving value is sent each tick.
//
// LIGHT, NOT PAINT. Each effect computes radiance L (rgb, may exceed 1) and is written as
//     colour = L / max(L),   alpha = 1 - exp(-max(L))
// With the pipeline's ordinary alpha blend this behaves like additive light where L is small (the scene
// shows through, brightened) and saturates to white-gold where L is large, instead of pasting a flat
// translucent colour over the screen. A 4x4 Bayer offset of half a step on alpha removes banding in the
// long soft falloffs.
//
//   flash      (r strength, g warmth)
//              L = s·(1.6 − 0.5·r + 0.8·smoothstep(0.6, 1.6, r)) — the eye is blinded hardest in the middle,
//              with a hot rim where the light wraps the edges; white tinted gold by warmth.
//   supernova  (r strength, g progress p, b phase φ), f = 1 − p
//              core   1.8·e^(−r²/(0.012 + 0.22 f))·f^1.5                       white-hot centre
//              halo   0.55·e^(−2.4 r)·f                                         warm wide glow
//              ring   1.5·f·g(r − R·(1 ± 0.014(1+p))),  R = 0.05 + 1.95 p     per channel, warm-tinted: a
//                                                                               gold-red fringe outside, a
//                                                                               paler one inside
//              burst  8 long + 8 short spikes, |cos|^60 in angle, each its own hashed length
//              streak e^(−|q.y|·38)·e^(−|q.x|·0.8)·f                            anamorphic lens streak
//              ghosts three soft hexagonal bokeh on the anti-diagonal, drifting out with p
//              edge   a warm red-orange glow at smoothstep(1.0, 1.8, r)
//   corona     (r strength, g pulse, b phase φ)
//              golden god rays reaching in from the edges: n = a·b + 0.35c with a, b, c the half-wave
//              sines of 23θ + 2πφ, 41θ − 4πφ and 9θ + 2πφ (integer multiples of φ, so the loop is seamless);
//              each shaft reaches (0.22 + 0.38n)(0.75 + 0.35·pulse) in from the edge and fades quadratically,
//              over a soft white-gold rim.

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec2 texCoord0;
flat in int fxKind;
in vec2 fxPos;
flat in vec4 fxParams;
flat in float fxAspect;

out vec4 fragColor;

const float TAU = 6.2831853;
const vec3 WHITE_HOT = vec3(1.00, 0.98, 0.90);
const vec3 WHITE_GOLD = vec3(1.00, 0.92, 0.70);
const vec3 GOLD = vec3(1.00, 0.72, 0.26);
const vec3 SOLAR = vec3(1.00, 0.46, 0.12);

float hash1(float n) {
    return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float gauss(float x, float w) {
    return exp(-(x * x) / (w * w));
}

float bayer4(vec2 p) {
    ivec2 i = ivec2(mod(p, 4.0));
    int idx = i.x + i.y * 4;
    const float M[16] = float[](0., 8., 2., 10., 12., 4., 14., 6., 3., 11., 1., 9., 15., 7., 13., 5.);
    return M[idx] / 16.0;
}

/** Signed distance to a hexagon of circumradius s (flat side up). */
float hexDist(vec2 p, float s) {
    p = abs(p);
    return max(dot(p, vec2(0.8660254, 0.5)), p.y) - s * 0.8660254;
}

vec4 asLight(vec3 L) {
    float peak = max(L.r, max(L.g, L.b));
    if (peak <= 0.0) {
        return vec4(0.0);
    }
    float a = 1.0 - exp(-peak);
    a += (bayer4(gl_FragCoord.xy) - 0.5) / 255.0;
    return vec4(L / peak, clamp(a, 0.0, 1.0));
}

vec3 flash(vec2 q, vec3 p) {
    float r = length(q);
    float s = p.r;
    float body = 1.6 - 0.5 * r + 0.8 * smoothstep(0.6, 1.6, r);
    vec3 tint = mix(WHITE_HOT, WHITE_GOLD, p.g);
    vec3 rim = mix(WHITE_GOLD, GOLD, p.g);
    return s * mix(tint, rim, smoothstep(0.8, 1.6, r)) * body;
}

vec3 supernova(vec2 q, vec3 p) {
    float prog = p.g;
    float f = 1.0 - prog;
    float r = length(q);
    float th = atan(q.y, q.x);
    float phase = p.b;

    vec3 L = vec3(0.0);
    L += WHITE_HOT * 1.8 * exp(-r * r / (0.012 + 0.22 * f)) * pow(f, 1.5);
    L += GOLD * 0.55 * exp(-2.4 * r) * f;

    float R = 0.05 + 1.95 * prog;
    float split = 0.014 * (1.0 + prog);
    float w = 0.022 + 0.09 * prog;
    vec3 ring = vec3(gauss(r - R * (1.0 + split), w), gauss(r - R, w), gauss(r - R * (1.0 - split), w));
    L += ring * vec3(1.0, 0.78, 0.42) * 1.5 * f;
    L += GOLD * gauss(r - R * 0.92, w * 2.5) * 0.35 * f;

    // starburst: 16 spikes, the even ones long; each spike gets its own length from a hash
    float a = th / TAU * 16.0 + phase * 16.0;
    float idx = floor(a + 0.5);
    float ang = abs(a - idx);
    float spike = pow(cos(ang * 3.14159265), 60.0);
    float len = (mod(idx, 2.0) < 0.5 ? 0.55 : 0.25) * (0.6 + 0.8 * hash1(idx + floor(phase * 97.0)));
    L += WHITE_GOLD * spike * exp(-r / max(0.02, len * (0.35 + 0.65 * f))) * 1.1 * f;

    // anamorphic streak through the centre
    L += mix(GOLD, WHITE_GOLD, 0.4) * exp(-abs(q.y) * 38.0) * exp(-abs(q.x) * 0.8) * 0.9 * f;

    // lens ghosts: soft hexagons on the anti-diagonal, brighter rims
    vec2 axis = normalize(vec2(-0.86, 0.5));
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float off = (0.35 + 0.42 * fi) * (0.5 + 0.9 * prog);
        float size = 0.05 + 0.035 * fi;
        float d = hexDist(q - axis * off, size);
        float body = smoothstep(0.01, -0.01, d) * 0.10;
        float rim = gauss(d, 0.008) * 0.22;
        vec3 tint = i == 1 ? vec3(0.55, 0.85, 1.0) : SOLAR;
        L += tint * (body + rim) * f;
    }

    L += vec3(1.0, 0.38, 0.12) * smoothstep(1.0, 1.8, r) * 0.45 * f;
    return L * p.r;
}

vec3 corona(vec2 q, vec3 p) {
    vec2 e = q / vec2(fxAspect, 1.0);
    float r = length(e);
    float th = atan(e.y, e.x);
    float pulse = p.g;
    float ph = p.b * TAU;
    // thin god rays: the product of two fast sines makes uneven streaks, a slow one groups them
    float a = 0.5 + 0.5 * sin(23.0 * th + ph);
    float b = 0.5 + 0.5 * sin(41.0 * th - 2.0 * ph);
    float c = 0.5 + 0.5 * sin(9.0 * th + ph);
    float n = a * b + 0.35 * c;
    float reach = (0.22 + 0.38 * n) * (0.75 + 0.35 * pulse);
    float edge = smoothstep(1.0 - reach, 1.55, r);
    edge *= edge;
    float rim = smoothstep(0.95, 1.6, r);
    vec3 L = GOLD * edge * (0.25 + 0.75 * n) + WHITE_GOLD * rim * rim * 0.55;
    return L * p.r;
}

void main() {
    if (fxKind == 0) {
        vec4 color = texture(Sampler0, texCoord0) * vertexColor * ColorModulator;
        if (color.a < 0.1) {
            discard;
        }
        fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
        return;
    }
    vec2 q = fxPos * vec2(fxAspect, 1.0);
    vec3 p = fxParams.rgb;
    vec3 L;
    if (fxKind == 1) {
        L = flash(q, p);
    } else if (fxKind == 2) {
        L = supernova(q, p);
    } else {
        L = corona(q, p);
    }
    vec4 c = asLight(L);
    c.a *= fxParams.a;
    if (c.a < 0.004) {
        discard;
    }
    fragColor = c;
}
