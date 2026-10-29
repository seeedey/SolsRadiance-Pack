#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:globals.glsl>

// Vanilla 1.21.11 entity.fsh, plus the Dawnsplitter's afterimage.
//
// Prism Step leaves a mannequin in the wielder's pose wearing the pack's afterimage skin
// (solradiance:entity/afterimage_N). Every texel of that skin has alpha exactly 241, which no vanilla
// entity texture uses; any other texel is drawn exactly as vanilla. The skin's channels are data, not
// colour:
//     r  edge: 1 along the border of each face of each body part, 0 inside
//     g  facet: a hashed value per 2x2 block, so the light breaks up like cut glass
//     b  fade: 1 when the afterimage appears, lower in the later skins the plugin swaps in
// The afterimage ignores the lightmap (it is light) and is drawn as
//     hue    = 3·v + 0.3·y + 0.35·facet − t            (v the skin's texture row, y the height, t the clock)
//     colour = mix(spectrum(hue), white, 0.2 + 0.6·rim² + 0.45·edge) · scan
//     alpha  = (0.28 + 0.6·rim + 0.35·edge) · fade
// rim = 1 − |N·V| lights the silhouette's outline, like light caught in the edge of glass; scan is a faint
// set of lines rolling up the screen; t runs one hue cycle every two seconds of game time.

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
#ifdef PER_FACE_LIGHTING
in vec4 vertexPerFaceColorBack;
in vec4 vertexPerFaceColorFront;
#else
in vec4 vertexColor;
#endif
in vec4 lightMapColor;
in vec4 overlayColor;
in vec2 texCoord0;
in vec3 fxPos;
in vec3 fxNormal;

out vec4 fragColor;

vec3 spectrum(float t) {
    return clamp(0.5 + 0.5 * cos(6.2831853 * (t - vec3(0.0, 0.333, 0.667))), 0.0, 1.0);
}

void main() {
    vec4 color = texture(Sampler0, texCoord0);
    if (abs(color.a * 255.0 - 241.0) < 0.5) {
        vec3 view = normalize(-fxPos);
        float rim = 1.0 - abs(dot(normalize(fxNormal), view));
        float t = GameTime * 600.0;
        float hue = texCoord0.y * 3.0 + fxPos.y * 0.3 + color.g * 0.35 - t;
        float scan = 0.85 + 0.15 * sin(gl_FragCoord.y * 1.3 - t * 40.0);
        vec3 c = mix(spectrum(hue), vec3(1.0), clamp(0.2 + 0.6 * rim * rim + 0.45 * color.r, 0.0, 1.0)) * scan;
        float a = clamp((0.28 + 0.6 * rim + 0.35 * color.r) * color.b, 0.0, 1.0);
        if (a < 0.02) {
            discard;
        }
        fragColor = apply_fog(vec4(c, a), sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
        return;
    }
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif
#ifdef PER_FACE_LIGHTING
    color *= (gl_FrontFacing ? vertexPerFaceColorFront : vertexPerFaceColorBack) * ColorModulator;
#else
    color *= vertexColor * ColorModulator;
#endif
#ifndef NO_OVERLAY
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayColor.a);
#endif
#ifndef EMISSIVE
    color *= lightMapColor;
#endif
    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}
