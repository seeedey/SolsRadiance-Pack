#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

// Vanilla 1.21.11 rendertype_item_entity_translucent_cull.fsh, plus the Falling Star's star and sky. Built on the
// technique of the Core shaders project (its frame recovery, sphere impostor, noise and clock): an item whose texel
// is a marker is not shaded as a picture; this shader draws something in its place and writes that thing's depth.
// Every other item takes the untouched vanilla path at the bottom of main().
//
// The marker is a flat colour (it survives the atlas's per-sprite mipmaps) that no vanilla item texture uses:
//     a = 250   the signature
//     r = 200   the star (solradiance:lodestar_star), r = 201 the sky (solradiance:lodestar_sky)
//     b         the clock: the sprite is animated, one frame a tick, b stepping 0..255 (the item pass has no time
//               uniform, so this is its only clock). The star's loop is 12.8 s, the sky's 25.6 s.
//
// THE STAR is a billboarded flat quad. Its frame comes back from screen derivatives and the provoking corner, the eye
// ray is intersected with a sphere in the quad's middle (0.38 of its half-width), and the miss draws the corona out to
// the quad's edge. Its tint is the plugin's three parameters:
//     r  heat       0 a gold-orange star, 1 white-hot with a blue-white rim (the collapse)
//     g  fury       how hard it boils and how far its streamers reach (the struggle, a torn chain)
//     b  flash      a white bloom over the whole star (the catch, each tug, each rupture)
// Surface: cellular granulation on the turning normal, a domain-warped fBm of hot gold veins, limb darkening and a
// moonlit fresnel rim. temperature T = 0.5 + 0.55·heat + 0.35·cell + 0.4·(veins − 0.5)·(1 + fury), colour = ramp(T).
// Corona: e^(−k(ρ − 1)) for ray-miss distance ρ (in radii), k = 4.2 − 2.2·fury, broken into streamers by noise on
// the direction of the closest approach (never by atan, which would leave a seam), plus a four-point flare.
// Its halo writes the depth one radius behind the star's centre, so whatever moves inside the glow (chains, debris,
// fire) stays in front of it.
//
// THE SKY is the whole screen behind everything else (the vertex shader puts it there). It depends on the eye ray d
// alone: a deep indigo gradient, a galactic band (great circle, normal nb) of violet-to-gold fBm cloud cut by ridged
// dust lanes with a gold bulge, faint nebulae, three twinkling star layers in their own colours, shooting stars, and
// round the Shackle constellation a gold glow that wakes as the star does. It blends into the fog colour at the
// horizon so it meets the distance fog of the terrain with no seam. Parameters:
//     tint r   presence    its alpha: 0 the vanilla sky, 1 this one
//     tint g   awaken      the gold glow round the constellation, and the band brightening with it
//     tint b   flash       a white-gold flash of the whole sky (the release)
//     light.x  the constellation's azimuth from the altar, in 16ths of a turn (its elevation is ~47°)
//     light.y  hush, 0..15: the sky dims and its stars go out as the star drinks the light

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec2 texCoord0;
in vec2 texCoord1;

in vec3 fxPos;
in vec2 fxLocal;
flat in vec4 fxTint;
flat in ivec2 fxLight;
flat in vec4 fxProjZW;
flat in vec3 fxCorner;
flat in vec2 fxCornerLocal;

out vec4 fragColor;

#define TAU 6.28318530718
// A zero the compiler cannot prove is zero: as a loop bound it stops the driver unrolling noise loops (compile time).
#define DYN0 (int(gl_FragCoord.x) >> 24)

const vec3 GOLD = vec3(1.0, 0.76, 0.28);
const vec3 MOON = vec3(0.72, 0.84, 1.0);

// ---- hashes and noise (after Dave Hoskins; the Core shaders noise kit) ------------------------------------------

float hash31(vec3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 hash33(vec3 p3) {
    p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// an offset that comes back to its start as the clock goes once round, so animated noise loops with no jump
vec3 loop3(float ph, float r) {
    float a = ph * TAU;
    return vec3(cos(a), sin(a), 0.0) * r;
}

vec4 h4(vec4 x, vec4 y, float z) {
    vec4 a = fract(x * 0.1031);
    vec4 b = fract(y * 0.1031);
    float c = fract(z * 0.1031);
    vec4 d = a * (c + 31.32) + b * (b + 31.32) + c * (a + 31.32);
    a += d;
    b += d;
    return fract((a + b) * (vec4(c) + d));
}

float vnoise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec4 xs = i.x + vec4(0.0, 1.0, 0.0, 1.0);
    vec4 ys = i.y + vec4(0.0, 0.0, 1.0, 1.0);
    vec4 hz = mix(h4(xs, ys, i.z), h4(xs, ys, i.z + 1.0), u.z);
    vec2 hy = mix(hz.xz, hz.yw, u.x);
    return mix(hy.x, hy.y, u.y);
}

float fbm4(vec3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4 + DYN0; i++) {
        s += a * vnoise3(p);
        p = p * 2.03 + vec3(1.7, 9.2, 4.1);
        a *= 0.5;
    }
    return s / 0.9375;
}

float ridged4(vec3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4 + DYN0; i++) {
        float n = 1.0 - abs(2.0 * vnoise3(p) - 1.0);
        s += a * n * n;
        p = p * 2.07 + vec3(3.1, 1.3, 7.7);
        a *= 0.5;
    }
    return s / 0.9375;
}

// cellular noise on the 2x2x2 block nearest the sample: x = distance to the nearest point, y = to the next
vec2 cell3(vec3 p) {
    vec3 o0 = floor(p) - step(fract(p), vec3(0.5));
    float d1 = 8.0, d2 = 8.0;
    for (int k = 0; k < 8 + DYN0; k++) {
        vec3 c = o0 + vec3(float(k & 1), float((k >> 1) & 1), float((k >> 2) & 1));
        vec3 r = c + 0.15 + 0.70 * hash33(c) - p;
        float d = dot(r, r);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
    }
    return sqrt(vec2(d1, d2));
}

vec3 rotAxis(vec3 p, vec3 k, float a) {
    float c = cos(a), s = sin(a);
    return p * c + cross(k, p) * s + k * dot(k, p) * (1.0 - c);
}

// ---- the quad's frame (Core shaders' frame recovery) --------------------------------------------------------------
// Edge directions from the screen derivatives of (position, quad corner), extents exactly from the provoking corner:
// P − Pc = T·(L.x − Lc.x) + B·(L.y − Lc.y) for any rotation.

struct Face {
    vec3 T;
    vec3 B;
    vec3 C;
    float edge;
    bool ok;
};

Face face(vec3 P, vec2 L, vec3 dPdx, vec3 dPdy, vec2 dLdx, vec2 dLdy, vec3 Pc, vec2 Lc) {
    Face f;
    f.T = vec3(1.0, 0.0, 0.0); f.B = vec3(0.0, 1.0, 0.0); f.C = P; f.edge = 1.0; f.ok = false;
    float det = dLdx.x * dLdy.y - dLdx.y * dLdy.x;
    if (abs(det) < 1e-24) return f;
    vec3 Td = (dPdx * dLdy.y - dPdy * dLdx.y) / det;
    vec3 Bd = (dPdy * dLdx.x - dPdx * dLdy.x) / det;
    float lTd = length(Td), lBd = length(Bd);
    if (lTd < 1e-12 || lBd < 1e-12) return f;
    vec3 t = Td / lTd;
    vec3 n = normalize(cross(t, Bd / lBd));
    vec3 b = cross(n, t);
    vec2 dl = L - Lc;
    vec3 d = P - Pc;
    float sx = abs(dl.x) < 1e-4 ? 1.0 : dl.x;
    float sy = abs(dl.y) < 1e-4 ? 1.0 : dl.y;
    float lt = mix(lTd, abs(dot(d, t) / sx), smoothstep(0.04, 0.20, abs(dl.x)));
    float lb = mix(lBd, abs(dot(d, b) / sy), smoothstep(0.04, 0.20, abs(dl.y)));
    f.T = t * lt;
    f.B = b * lb;
    f.C = P - f.T * (L.x - 0.5) - f.B * (L.y - 0.5);
    f.edge = 0.5 * (lt + lb);
    f.ok = true;
    return f;
}

// ---- the star ------------------------------------------------------------------------------------------------------

const float STAR_FILL = 0.38;

// temperature to colour: ember, orange, gold, white-gold, white, blue-white
vec3 ramp(float T) {
    vec3 c = mix(vec3(0.55, 0.10, 0.02), vec3(1.0, 0.42, 0.06), smoothstep(0.0, 0.45, T));
    c = mix(c, GOLD, smoothstep(0.35, 0.75, T));
    c = mix(c, vec3(1.0, 0.95, 0.80), smoothstep(0.70, 1.05, T));
    c = mix(c, vec3(1.0), smoothstep(1.0, 1.3, T));
    return mix(c, vec3(0.86, 0.93, 1.0), smoothstep(1.3, 1.6, T));
}

bool star(vec3 eye, Face f, float ph, vec3 k, out vec4 col, out vec3 dp) {
    col = vec4(0.0);
    dp = fxPos;
    float heat = k.r, fury = k.g, flash = k.b;
    vec3 C = f.C;
    float R = f.edge * 0.5 * STAR_FILL;
    float b = dot(eye, C);
    float cc = dot(C, C) - R * R;
    if (b <= 0.0 || cc < 0.0) return false;            // behind the camera, or the camera is inside it
    float disc = b * b - cc;
    float rho = sqrt(max(0.0, R * R - disc)) / R;        // closest approach of the ray, in radii
    vec3 gaze = -normalize(C);
    vec3 axis = normalize(vec3(0.25, 1.0, 0.18));

    if (disc >= 0.0) {
        vec3 hit = eye * (b - sqrt(disc));
        vec3 n = normalize(hit - C);
        float ndv = clamp(dot(n, gaze), 0.0, 1.0);
        // the surface turns once a loop; the veins run the other way, faster when it fights
        vec3 p = rotAxis(n, axis, ph * TAU);
        vec3 q = rotAxis(n, axis, -ph * TAU * 2.0);
        vec2 g = cell3(p * 7.0 + loop3(ph, 0.6));
        float cell = pow(1.0 - clamp(g.x * 1.3, 0.0, 1.0), 1.5);
        float lane = smoothstep(0.0, 0.12, g.y - g.x);                    // dark lanes between the cells
        vec3 warp = vec3(fbm4(q * 2.2 + loop3(ph, 0.5)), fbm4(q * 2.2 + vec3(5.2, 1.3, 2.8)), 0.0);
        float veins = ridged4(q * 3.0 + warp * (1.2 + 1.5 * fury) + loop3(ph, 0.4));
        float T = 0.5 + 0.55 * heat + 0.35 * cell * lane + 0.4 * (veins - 0.5) * (1.0 + fury);
        vec3 c = ramp(T) * mix(1.0, 1.25, veins * veins);
        c *= mix(mix(0.45, 0.8, heat), 1.0, pow(ndv, 0.5));            // limb darkening, less when white-hot
        c += mix(GOLD, MOON, 0.4 + 0.6 * heat) * pow(1.0 - ndv, 3.0) * (0.55 + 0.6 * heat);
        c = mix(c, vec3(1.0, 0.98, 0.92) * 1.3, flash * 0.75);
        col = vec4(c, 1.0);
        dp = hit;
        return true;
    }

    // the corona
    vec3 near = eye * b;
    vec3 side = normalize(near - C);
    float s1 = vnoise3(side * 3.4 + loop3(ph, 0.9));
    float s2 = vnoise3(side * 9.0 + loop3(ph, 1.3) + vec3(7.0));
    float streamer = 0.35 + 1.1 * s1 * s1 + 0.45 * s2 * (1.0 + fury);
    float x = rho - 1.0;
    float kfall = 4.2 - 2.2 * fury;
    float glow = exp(-x * kfall / max(0.4, streamer));
    float rim = pow(1.0 - smoothstep(0.0, 0.16, x), 2.0);
    vec2 u = abs(fxLocal * 2.0 - 1.0);
    float flare = exp(-u.x * 60.0) * exp(-u.y * 2.2) + exp(-u.y * 60.0) * exp(-u.x * 2.2);
    flare *= 0.25 + 0.6 * heat + 0.9 * flash;
    float a = glow * (0.55 + 0.25 * fury) + rim * 0.6 + flare;
    a *= 1.0 - smoothstep(0.75, 1.0, max(u.x, u.y));          // nothing reaches the quad's edge
    a = clamp(a * (1.0 + flash), 0.0, 0.95);
    vec3 c = mix(ramp(0.55 + 0.55 * heat), vec3(1.0, 0.96, 0.86), rim * 0.7 + 0.3 * heat);
    c = mix(c, vec3(1.0), clamp(flare + flash * 0.5, 0.0, 1.0));
    col = vec4(c * 1.15, a);
    dp = eye * (b + R);
    return a >= 0.03;
}

// ---- the sky -----------------------------------------------------------------------------------------------------

// a layer of stars on the sphere of directions: rgb, each in its own colour, twinkling with the clock
vec3 starLayer(vec3 d, float scale, float size, float seed, float ph) {
    vec3 p = d * scale;
    vec3 i = floor(p);
    vec3 h = hash33(i + seed);
    float on = step(0.74, hash31(i + seed + 7.0));
    float dist = length(fract(p) - h);
    float tw = 0.6 + 0.4 * sin(ph * TAU * (2.0 + floor(h.z * 3.0)) + h.x * TAU);
    vec3 tint = mix(vec3(0.70, 0.80, 1.0), vec3(1.0, 0.82, 0.55), h.y);
    return tint * on * tw * pow(clamp(1.0 - dist / size, 0.0, 1.0), 3.0);
}

vec3 meteors(vec3 d, float ph) {
    vec3 acc = vec3(0.0);
    for (int k = 0; k < 2 + DYN0; k++) {
        float clock = ph * 7.0 + float(k) * 0.5;
        float slot = floor(clock);
        float life = fract(clock) / 0.3;                  // each one crosses in 0.3 of its slot, ~1.1 s
        vec3 h = hash33(vec3(slot, float(k), 3.0));
        if (h.x > 0.55 || life > 1.0) continue;
        vec3 s = normalize(vec3(h.y * 2.0 - 1.0, 0.45 + 0.5 * h.z, h.x * 3.0 - 1.0));
        vec3 m = normalize(cross(s, vec3(h.z - 0.5, 1.0, h.y - 0.5)));
        float head = life * 0.45;
        vec3 r = d - s;
        float along = dot(r, m);
        float across = length(r - m * along);
        float tail = clamp((head - along) / 0.14, 0.0, 1.0);
        float on = step(0.0, head - along) * (1.0 - tail);
        acc += vec3(1.0, 0.92, 0.75) * on * exp(-across * across / 4e-6) * sin(3.14159 * life);
    }
    return acc;
}

vec4 sky(vec3 d, float ph, vec3 k, ivec2 light) {
    float presence = k.r, awaken = k.g, flash = k.b;
    float hush = float(light.y) / 15.0;
    float up = d.y;
    vec3 col = mix(vec3(0.026, 0.034, 0.085), vec3(0.003, 0.005, 0.020), smoothstep(-0.05, 0.65, up));

    // the galactic band: a river of faint light, soft dust patches and one thin dark lane down it, a small gold bulge
    vec3 nb = normalize(vec3(0.42, 0.50, -0.76));
    float bd = dot(d, nb);
    float band = exp(-bd * bd / 0.022);
    float cloud = fbm4(d * 3.4 + loop3(ph, 0.22));
    float dust = smoothstep(0.55, 0.80, fbm4(d * 7.0 + vec3(2.0, 7.0, 1.0))) * 0.55
               + exp(-(bd - 0.025) * (bd - 0.025) / 0.0003) * 0.45 * smoothstep(0.35, 0.6, cloud);
    vec3 gc = normalize(vec3(0.80, 0.35, 0.50) - nb * dot(vec3(0.80, 0.35, 0.50), nb));
    float bulge = pow(max(dot(d, gc), 0.0), 40.0);
    vec3 bandCol = mix(vec3(0.30, 0.32, 0.58), vec3(0.62, 0.66, 0.86), cloud);
    bandCol = mix(bandCol, vec3(1.0, 0.78, 0.48), bulge);
    col += bandCol * band * (0.05 + 0.20 * cloud * cloud + 0.35 * bulge) * (1.0 + 0.5 * awaken) * (1.0 - dust * band);

    // faint nebulae, teal into rose
    float neb = fbm4(d * 1.6 + vec3(9.0) + loop3(ph, 0.12));
    col += mix(vec3(0.04, 0.20, 0.26), vec3(0.34, 0.08, 0.24), fbm4(d * 2.3 + vec3(3.0))) * smoothstep(0.58, 0.86, neb) * 0.12;

    // the stars: four layers, crowding into the band, and a few bright ones with a soft glow
    vec3 st = starLayer(d, 70.0, 0.26, 1.0, ph) + 0.8 * starLayer(d, 140.0, 0.32, 9.0, ph)
            + 0.6 * starLayer(d, 260.0, 0.40, 4.0, ph) * (0.4 + 2.0 * band);
    vec3 bp = d * 18.0;
    vec3 bh = hash33(floor(bp) + 21.0);
    float bright = step(0.86, hash31(floor(bp) + 13.0)) * exp(-length(fract(bp) - (0.25 + 0.5 * bh)) * 26.0);
    st += mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.85, 0.6), bh.x) * bright * (2.2 + 0.8 * sin(ph * TAU * 3.0 + bh.y * TAU));
    col += st * 1.5 * (1.0 + 1.2 * band) * (1.0 - 0.9 * hush) * smoothstep(-0.02, 0.10, up);
    col += meteors(d, ph) * (1.0 - hush);

    // round the Shackle: a gold glow that wakes with the Lodestar, turning slowly, rose at its fringe
    float az = float(light.x) * TAU / 16.0;
    vec3 cd = vec3(cos(az) * 0.68, 0.73, sin(az) * 0.68);
    float near = max(dot(d, cd), 0.0);
    float swirl = fbm4(rotAxis(d, cd, ph * TAU) * 4.0 + vec3(1.0, 4.0, 2.0));
    float wisp = smoothstep(0.35, 0.8, swirl);
    vec3 halo = mix(vec3(0.85, 0.30, 0.38), vec3(1.0, 0.80, 0.36), smoothstep(0.6, 0.95, near));
    col += halo * awaken * (pow(near, 14.0) * (0.25 + 0.9 * wisp) + pow(near, 40.0) * 0.4);

    col *= 1.0 - 0.6 * hush;
    col = mix(FogColor.rgb, col, smoothstep(-0.03, 0.16, up));      // meet the terrain's distance fog
    col = mix(col, vec3(1.0, 0.93, 0.76), flash * 0.85);
    return vec4(col, presence);
}

// ---- entry -------------------------------------------------------------------------------------------------------

void main() {
    vec4 texel = texture(Sampler0, texCoord0);

    // derivatives have to be taken in uniform control flow, so before any branch
    vec3 dPdx = dFdx(fxPos);
    vec3 dPdy = dFdy(fxPos);
    vec2 dLdx = dFdx(fxLocal);
    vec2 dLdy = dFdy(fxLocal);

    vec4 m = texel * 255.0;
    if (abs(m.a - 250.0) < 0.5 && (abs(m.r - 200.0) < 0.5 || abs(m.r - 201.0) < 0.5)) {
        float ph = floor(m.b + 0.5) / 256.0;
        if (m.r > 200.5) {
            gl_FragDepth = gl_FragCoord.z;
            fragColor = sky(normalize(fxPos), ph, fxTint.rgb, fxLight);
            return;
        }
        Face f = face(fxPos, fxLocal, dPdx, dPdy, dLdx, dLdy, fxCorner, fxCornerLocal);
        vec4 col;
        vec3 dp;
        if (!f.ok || !star(normalize(fxPos), f, ph, fxTint.rgb, col, dp)) {
            discard;
        }
        float zView = (ModelViewMat * vec4(dp, 1.0)).z;
        gl_FragDepth = 0.5 + 0.5 * (fxProjZW.x * zView + fxProjZW.y) / (fxProjZW.z * zView + fxProjZW.w);
        fragColor = vec4(min(col.rgb, vec3(1.0)), col.a);
        return;
    }

    gl_FragDepth = gl_FragCoord.z;
    vec4 color = texel * vertexColor * ColorModulator;
    if (color.a < 0.1) {
        discard;
    }
    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}
