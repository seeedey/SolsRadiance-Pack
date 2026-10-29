#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

// Vanilla 1.21.11 rendertype_text.vsh plus Sol's Radiance's screen effects. Every glyph that is not
// one of ours is drawn exactly as vanilla.
//
// The plugin sends a title made of solradiance:fx glyphs. Each is a solid square of a KEY colour no real
// glyph uses (texture rgb 211, 70..75, 250). A key glyph's quad is moved to cover the whole screen and
// its text colour carries the effect's three parameters. The font pushes the glyphs 1249 units below the
// title line (5000 after the title's 4x scale), so only GUI text that far down is ever tested: a sign or
// a text display in the world can never trigger an effect.
//
// The corner each vertex goes to comes from the glyph's vertex order, fixed in 1.21.11: top-left,
// bottom-left, bottom-right, top-right. The same order says which way is into the glyph, so the key is
// sampled a texel and a half inward of the vertex's own UV (sampling at the corner would land on the
// neighbouring glyph in the atlas).

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in ivec2 UV2;

uniform sampler2D Sampler0;
uniform sampler2D Sampler2;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;
out vec2 texCoord0;
flat out int fxKind;
out vec2 fxPos;
flat out vec4 fxParams;
flat out float fxAspect;

const vec2 CORNER[4] = vec2[](vec2(-1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0));
const vec2 INWARD[4] = vec2[](vec2(1.0, 1.0), vec2(1.0, -1.0), vec2(-1.0, -1.0), vec2(-1.0, 1.0));

int keyAt(vec2 uv) {
    vec4 c = textureLod(Sampler0, uv, 0.0);
    if (c.a < 0.99) {
        return 0;
    }
    ivec3 k = ivec3(round(c.rgb * 255.0));
    if (k.r != 211 || k.b != 250 || k.g < 70 || k.g > 75) {
        return 0;
    }
    return k.g - 69;          // 1 flash, 2 supernova, 3 corona, 4 swirl, 5 cracks, 6 prism
}

void main() {
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);
    vertexColor = Color * texelFetch(Sampler2, UV2 / 16, 0);
    texCoord0 = UV0;
    fxKind = 0;
    fxPos = vec2(0.0);
    fxParams = Color;
    fxAspect = 16.0 / 9.0;

    if (Position.y > 2000.0 && Color.a > 0.02) {
        vec2 texel = 1.0 / vec2(textureSize(Sampler0, 0));
        int v = gl_VertexID % 4;
        int key = keyAt(UV0 + INWARD[v] * texel * 1.5);
        if (key > 0) {
            fxKind = key;
            gl_Position = vec4(CORNER[v], 0.0, 1.0);
            fxPos = CORNER[v];
            float sx = abs(ProjMat[0][0]);
            float sy = abs(ProjMat[1][1]);
            fxAspect = sx > 0.0 ? sy / sx : 16.0 / 9.0;
        }
    }
}
