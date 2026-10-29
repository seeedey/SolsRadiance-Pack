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
//   flash      (r strength, g warmth, b cool)
//              L = s·(1.6 − 0.5·r + 0.8·smoothstep(0.6, 1.6, r)) — the eye is blinded hardest in the middle,
//              with a hot rim where the light wraps the edges; white tinted gold by warmth, or toward
//              moonlight by cool.
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
//   swirl      (r strength, g hue: 0 gold, 1 moonlight, b phase φ)
//              a storm of light at the screen edges. The view is turned by 1.6/(0.6 + r) + 2πφ (a whirl,
//              tighter toward the middle), domain-warped twice by 4-octave value noise whose offset runs
//              round a circle of radius 0.8 with φ (so the loop is seamless): n = fbm(2.2w + 2.5·warp).
//              Body 0.85·smoothstep(0.35, 0.75, n), streaks 1.1·(1 − |2n − 1|)^6, kept to the band
//              smoothstep(0.45, 1.2, r).
//   cracks     (r strength, g reach, b shimmer phase φ)
//              cracked glass closing in from the edges: a Voronoi in polar coordinates (13 cells round,
//              rows in 3.2·ln r, so cells grow toward the edges as on a shell seen from inside, and the
//              seam at θ = ±π wraps). d = F2 − F1 is the distance to the nearest crack: a white-hot line
//              e^(−d/0.035), a gold halo e^(−d/0.16), a faint amber in the cells, all beyond the radius
//              1.45 − 1.40·reach and clear of the very middle. Feature points keep 0.12 inside their cell,
//              so the 3×3 search always finds the true two nearest. Each cell's halo shimmers by 0.75 + 0.25·sin(40·id + 2πφ).
//   prism      (r strength, g ring progress p: 1 = no ring, b phase φ)
//              the Dawnsplitter's light split into its colours. spectrum(t) = ½ + ½cos(2π(t − (0, ⅓, ⅔))).
//              facets  a triangular lattice (3.4 per screen height) at the edges, smoothstep(0.7, 1.35, r):
//                      each triangle a pane of tinted glass, spectrum(id + θ/4π + ⅛sin(φ + 2π·id)), shimmering
//                      by 0.65 + 0.35 sin(2φ + 40 id), with white-hot leading e^(−d/0.028) along its edges
//              rays    12 shafts turning with φ, |cos|^24 in angle, each shaft's colour running through the
//                      spectrum with r, reaching in from the edges
//              ring    a dispersion ring at R = 0.06 + 1.9p, width w = 0.04 + 0.13p: across it the colour
//                      runs red (outside) to violet (inside), x = (r − R)/w, spectrum(0.5 + 0.35x)·e^(−x²),
//                      over a white core e^(−6x²); with a white burst e^(−r²/0.04) at the centre, all
//                      fading with (1 − p)

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
const vec3 MOON_WHITE = vec3(0.86, 0.95, 1.00);
const vec3 MOON_CYAN = vec3(0.45, 0.82, 1.00);
const vec3 AMBER = vec3(0.80, 0.48, 0.12);

float hash1(float n) {
    return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 x) {
    vec2 i = floor(x);
    vec2 f = fract(x);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash2(i);
    float b = hash2(i + vec2(1.0, 0.0));
    float c = hash2(i + vec2(0.0, 1.0));
    float d = hash2(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 x) {
    float s = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        s += a * vnoise(x);
        x = x * 2.03 + vec2(17.1, 9.2);
        a *= 0.5;
    }
    return s;
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
    vec3 tint = mix(mix(WHITE_HOT, WHITE_GOLD, p.g), MOON_WHITE, p.b);
    vec3 rim = mix(mix(WHITE_GOLD, GOLD, p.g), MOON_CYAN, p.b);
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

vec3 swirl(vec2 q, vec3 p) {
    vec2 e = q / vec2(fxAspect, 1.0);
    float r = length(e);
    float ph = p.b * TAU;
    float a = 1.6 / (0.6 + r) + ph;
    vec2 w = mat2(cos(a), -sin(a), sin(a), cos(a)) * q;
    vec2 loop = 0.8 * vec2(cos(ph), sin(ph));
    vec2 warp = vec2(fbm(w * 1.4 + loop), fbm(w * 1.4 - loop + 5.2));
    float n = fbm(w * 2.2 + 2.5 * warp);
    float streak = pow(1.0 - abs(2.0 * n - 1.0), 6.0);
    float body = smoothstep(0.35, 0.75, n);
    float band = smoothstep(0.45, 1.2, r);
    vec3 deep = mix(GOLD, MOON_CYAN, p.g);
    vec3 bright = mix(WHITE_GOLD, MOON_WHITE, p.g);
    return (deep * body * 0.85 + bright * streak * 1.1) * band * p.r;
}

vec3 cracks(vec2 q, vec3 p) {
    vec2 e = q / vec2(fxAspect, 1.0);
    float r = length(e);
    float th = atan(e.y, e.x);
    const float P = 13.0;
    vec2 g = vec2(th / TAU * P, log(max(r, 0.05)) * 3.2);
    vec2 i = floor(g);
    vec2 f = fract(g);
    float d1 = 8.0;
    float d2 = 8.0;
    float id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 c = vec2(float(x), float(y));
            vec2 cell = vec2(mod(i.x + c.x, P), i.y + c.y);
            vec2 o = 0.12 + 0.76 * vec2(hash2(cell), hash2(cell + 7.3));
            vec2 dv = c + o - f;
            float dd = dot(dv, dv);
            if (dd < d1) {
                d2 = d1;
                d1 = dd;
                id = hash2(cell + 3.1);
            } else if (dd < d2) {
                d2 = dd;
            }
        }
    }
    float d = sqrt(d2) - sqrt(d1);
    float line = exp(-d / 0.035);
    float halo = exp(-d / 0.16);
    float edge = 1.45 - 1.40 * p.g;
    float mask = smoothstep(edge - 0.25, edge + 0.15, r) * smoothstep(0.06, 0.32, r);
    float shimmer = 0.75 + 0.25 * sin(id * 40.0 + p.b * TAU);
    return (AMBER * 0.30 + GOLD * halo * 0.6 * shimmer + WHITE_HOT * line * 1.6) * mask * p.r;
}

vec3 spectrum(float t) {
    return clamp(0.5 + 0.5 * cos(TAU * (t - vec3(0.0, 0.333, 0.667))), 0.0, 1.0);
}

vec3 prism(vec2 q, vec3 p) {
    vec2 e = q / vec2(fxAspect, 1.0);
    float r = length(e);
    float th = atan(e.y, e.x);
    float ph = p.b * TAU;
    float prog = p.g;
    float f = 1.0 - prog;
    vec3 L = vec3(0.0);

    // facets: a triangular lattice; each triangle its own pane of tinted glass, leaded in white
    vec2 s = q * 3.4;
    vec2 t = vec2(s.x - s.y * 0.57735, s.y * 1.1547);
    vec2 ci = floor(t);
    vec2 cf = fract(t);
    float upper = step(1.0, cf.x + cf.y);
    float id = hash2(ci + upper * vec2(17.0, 31.0));
    float d = upper > 0.5 ? min(min(1.0 - cf.x, 1.0 - cf.y), (cf.x + cf.y - 1.0) * 0.7071)
                          : min(min(cf.x, cf.y), (1.0 - cf.x - cf.y) * 0.7071);
    float band = smoothstep(0.7, 1.35, r);
    float shimmer = 0.65 + 0.35 * sin(2.0 * ph + id * 40.0);
    vec3 pane = spectrum(id + th / (2.0 * TAU) + 0.125 * sin(ph + id * TAU));
    L += pane * 0.42 * shimmer * band;
    L += WHITE_HOT * exp(-d / 0.028) * 0.6 * band;

    // rays: twelve shafts turning with the phase, each running through the spectrum along its length
    float a = th / TAU * 12.0 + p.b;
    float ray = pow(abs(cos(3.14159265 * a)), 24.0);
    L += spectrum(r * 0.7 - p.b) * ray * smoothstep(0.35, 1.4, r) * 0.8;

    // the dispersion ring and its white heart
    if (prog < 1.0) {
        float R = 0.06 + 1.9 * prog;
        float w = 0.04 + 0.13 * prog;
        float rq = length(q);                 // true screen distance, so the ring is round
        float x = (rq - R) / w;
        L += spectrum(0.5 + 0.35 * x) * exp(-x * x) * 1.5 * f;
        L += WHITE_HOT * exp(-6.0 * x * x) * 0.7 * f;
        L += WHITE_HOT * exp(-rq * rq / 0.04) * 1.6 * f * f;
    }
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
    } else if (fxKind == 3) {
        L = corona(q, p);
    } else if (fxKind == 4) {
        L = swirl(q, p);
    } else if (fxKind == 5) {
        L = cracks(q, p);
    } else {
        L = prism(q, p);
    }
    vec4 c = asLight(L);
    c.a *= fxParams.a;
    if (c.a < 0.004) {
        discard;
    }
    fragColor = c;
}
