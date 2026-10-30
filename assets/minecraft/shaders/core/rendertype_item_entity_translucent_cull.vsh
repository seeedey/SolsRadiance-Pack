#version 330

#moj_import <minecraft:light.glsl>
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

// Vanilla 1.21.11 rendertype_item_entity_translucent_cull.vsh, plus the Falling Star's two shader-drawn things (see the
// .fsh): the star's body, and the night sky that replaces the vanilla one round the Lodestar Altar. Every other item
// is drawn exactly as vanilla. (texCoord2 is written with an explicit vec2(): vanilla's implicit ivec2 -> vec2 copy is
// accepted by desktop GL 3.30 but not by strict compilers.)
//
// The sky is one quad that this shader throws to the far plane over the whole screen. Its sprite is a marker
// (alpha 250, red 201) and its model's face takes the sprite's middle (uv 4..12), so the texel read at every corner
// lies inside the sprite and is the marker too. Its fragments then only need the eye ray, which is passed in fxPos.
//
// fxPos          camera-relative position in world orientation (Minecraft bakes the entity's pose into the vertices,
//                so ModelViewMat is the camera rotation only); for the sky, the eye ray at this corner of the screen
// fxLocal        the corner of the quad: (0,0) (1,0) (1,1) (0,1). Minecraft draws every quad as four consecutive
//                vertices through the shared index buffer, so gl_VertexID & 3 is the corner
// fxCorner/Local the provoking vertex of the triangle: an exact corner for rebuilding the quad's size
// fxTint         the item's tint, custom_model_data colors[0]: the plugin's three parameters
// fxLight        the display's brightness override (block, sky): two more, 0..15 each
// fxProjZW       the rows of ProjMat the fragment shader needs to write its own depth

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in vec2 UV1;
in ivec2 UV2;
in vec3 Normal;

uniform sampler2D Sampler0;
uniform sampler2D Sampler2;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;
out vec2 texCoord0;
out vec2 texCoord1;
out vec2 texCoord2;

out vec3 fxPos;
out vec2 fxLocal;
flat out vec4 fxTint;
flat out ivec2 fxLight;
flat out vec4 fxProjZW;
flat out vec3 fxCorner;
flat out vec2 fxCornerLocal;

void main() {
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);
    vertexColor = minecraft_mix_light(Light0_Direction, Light1_Direction, Normal, Color) * texelFetch(Sampler2, UV2 / 16, 0);
    texCoord0 = UV0;
    texCoord1 = UV1;
    texCoord2 = vec2(UV2);

    int corner = gl_VertexID & 3;
    fxLocal = vec2(float(((corner + 1) >> 1) & 1), float(corner >> 1));
    fxPos = Position;
    fxTint = Color;
    fxLight = UV2 / 16;
    fxCorner = Position;
    fxCornerLocal = fxLocal;
    fxProjZW = vec4(ProjMat[2][2], ProjMat[3][2], ProjMat[2][3], ProjMat[3][3]);

    vec4 m = textureLod(Sampler0, UV0, 0.0) * 255.0;
    if (abs(m.a - 250.0) < 0.5 && abs(m.r - 201.0) < 0.5) {
        // the sky: corners (-1,-1) (1,-1) (1,1) (-1,1), counter-clockwise so the face is never culled, just in front of
        // the far plane so it paints only where nothing has been drawn yet
        vec2 ndc = fxLocal * 2.0 - 1.0;
        gl_Position = vec4(ndc, 0.9999999, 1.0);
        vec4 ray = inverse(ProjMat) * vec4(ndc, 1.0, 1.0);
        fxPos = inverse(mat3(ModelViewMat)) * (ray.xyz / ray.w);
    }
}
