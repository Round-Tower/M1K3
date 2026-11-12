//
//  Phosphor.metal
//  M1K3App
//
//  RealityKit CustomMaterial surface shader: a fresnel/rim emissive over a
//  near-black body — the "phosphor skin" for the animated 3D companion (the fox).
//  The edge-box wireframe (scratch/phosphor-spike) can't follow a SKINNED mesh;
//  a per-fragment surface shader is blind to the skeleton, so it rides any
//  animation for free. Bright at grazing angles (the silhouette/edges), dark
//  facing the camera — the same additive-glow lattice as the site, on a creature.
//
//  Lives in the APP target (not a SwiftPM package) because SwiftPM does not
//  compile .metal; Xcode compiles this into the app's default.metallib, loaded
//  via Bundle.main (see PhosphorMaterial.swift). Validated host-independent with
//  `xcrun -sdk macosx metal -c` against the RealityKit headers.
//
//  The look is data-driven: colour (xyz) + fresnel power (w) arrive via the
//  material's custom_parameter, so the app can shift it with M1K3's state
//  (PhosphorTreatment) without recompiling the shader.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85 (shader compiles
//  against the RealityKit metal headers; render quality is verify-at-⌘R).
//  Prior: Unknown.
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

[[visible]]
void phosphorSurface(realitykit::surface_parameters params)
{
    auto surface = params.surface();
    auto geometry = params.geometry();

    // Colour + fresnel power supplied by the app (PhosphorTreatment.customValue).
    float4 custom = params.uniforms().custom_parameter();
    float3 phosphor = custom.xyz;
    float power = max(custom.w, 0.5); // guard against an unset (zero) parameter

    // Fresnel: 1 at grazing angles, 0 facing the camera. Raised to `power` so the
    // glow hugs the silhouette/edges (the phosphor lattice feel).
    float3 n = normalize(geometry.normal());
    float3 view = normalize(geometry.view_direction());
    float facing = saturate(dot(n, view));
    float rim = pow(1.0 - facing, power);

    // A faint constant floor so the body reads as a dark phosphor shell, not a
    // void, between the bright edges.
    float glow = rim + 0.04;

    surface.set_base_color(half3(0.02h, 0.04h, 0.03h)); // near-black body
    surface.set_emissive_color(half3(phosphor) * half(glow));
    surface.set_metallic(0.0h);
    surface.set_roughness(1.0h);
}

// Cel / toon shading — the creature's OWN texture, lit in flat cartoon bands with
// a bold ink outline. The cel signature is banding the LIGHT, not the colour:
// posterising the albedo fragments the fur into camo blotches, so we keep the fur
// faithful and quantise N·L into a few BRIGHT steps (cel is bold + flat, never
// muddy). Distinct from phosphor's monochrome glow; not state-reactive (the fur is
// the point — phosphor is the reactive one).
[[visible]]
void celSurface(realitykit::surface_parameters params)
{
    auto surface = params.surface();
    auto geometry = params.geometry();
    auto tex = params.textures();

    constexpr sampler bilinear(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float2 uv = geometry.uv0();

    // The creature's OWN fur colour, kept faithful (NOT posterised).
    half3 fur = tex.base_color().sample(bilinear, uv).rgb
        * half3(params.material_constants().base_color_tint());

    // Toon lighting: three BRIGHT flat bands (lit / mid / shadow). The shadow band
    // is still 0.62 so the fur colour reads everywhere — cartoon, not gloom.
    float3 n = normalize(geometry.normal());
    float3 light = normalize(float3(0.35, 0.7, 0.9));
    float ndl = saturate(dot(n, light));
    float toon = ndl > 0.66h ? 1.0h : (ndl > 0.33h ? 0.82h : 0.62h);

    // Bold ink outline at the silhouette — the defining cel line. Wider/softer than
    // the phosphor rim (threshold 0.78, gentle power 1.6) so it reads as a drawn edge.
    float3 view = normalize(geometry.view_direction());
    float ink = step(0.78, pow(1.0 - saturate(dot(n, view)), 1.6));

    half3 shaded = fur * half(toon);
    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(mix(shaded, half3(0.0h), half(ink)));
    surface.set_metallic(0.0h);
    surface.set_roughness(1.0h);
}

// The speaking glow (SpeakingGlow, PhosphorMaterial halo): a soft halo around the
// creature while M1K3's voice is speaking. It is drawn on a SHELL: a second copy of
// the creature's own skinned geometry, added at load, so it rides the skeleton.
// `haloGeometry` pushes the shell out along its (smoothed) normals; the material
// culls FRONT faces, so the body hides the shell everywhere except just beyond the
// silhouette; `haloSurface` fades it to nothing at its outer edge.
//
// The motion runs on the shader's own clock: a slow breath, and a band of light
// that travels across the creature. The app writes only a level, on change.
//
//   custom_parameter().x  the level, 0 (off) to 1; NEGATIVE means hold still
//                         (Reduce Motion, a parked creature)
//   custom_parameter().y  the shell's width, in the mesh's own units
//   custom_parameter().z  the shell's opacity at full level (the halo is nested
//                         shells, each wider and fainter: SpeakingGlow.shells)
//   emissive_color        the glow's colour
//
// Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.6 (compiles against the
// RealityKit headers; the look is judged by launch). Prior: Unknown.

// normalize() of a zero vector is NaN, and a NaN offset or opacity is undefined on screen.
static inline float3 haloSafeNormal(float3 v)
{
    return v * rsqrt(max(dot(v, v), 1e-12));
}

static inline float haloBreath(float signedLevel, float time)
{
    return signedLevel > 0.0 ? 0.88 + 0.12 * sin(time * 4.6) : 1.0;
}

[[visible]]
void haloGeometry(realitykit::geometry_parameters params)
{
    auto geometry = params.geometry();
    float4 custom = params.uniforms().custom_parameter();
    float level = saturate(fabs(custom.x));
    float width = custom.y * mix(0.45, 1.0, level) * haloBreath(custom.x, params.uniforms().time());
    geometry.set_model_position_offset(haloSafeNormal(geometry.normal()) * width);
}

[[visible]]
void haloSurface(realitykit::surface_parameters params)
{
    auto surface = params.surface();
    auto geometry = params.geometry();
    float4 custom = params.uniforms().custom_parameter();
    float level = saturate(fabs(custom.x));
    float time = params.uniforms().time();

    // Back faces of the shell: nearly edge-on at the shell's own outline (fade to
    // nothing there), turning toward the camera where the shell meets the body.
    float3 n = haloSafeNormal(geometry.normal());
    float3 view = haloSafeNormal(geometry.view_direction());
    float edge = smoothstep(0.0, 0.5, fabs(dot(n, view)));

    // A band of light travelling across the creature, in units of the shell's
    // width so it scales with the mesh. Still when the level is negative.
    float travel = 1.0;
    if (custom.x > 0.0) {
        float span = max(custom.y, 1e-5) * 9.0;
        float phase = dot(geometry.model_position(), normalize(float3(0.5, 1.0, 0.3))) / span;
        float band = pow(0.5 + 0.5 * sin(phase * 6.2832 - time * 3.2), 3.0);
        travel = 0.6 + 0.4 * band;
    }

    float glow = edge * level * travel * haloBreath(custom.x, time) * custom.z;
    float3 colour = params.material_constants().emissive_color();
    // The unlit lighting model shows the BASE colour (an emissive-only halo drew black).
    surface.set_base_color(half3(colour));
    surface.set_emissive_color(half3(colour));
    surface.set_opacity(half(glow));
    surface.set_metallic(0.0h);
    surface.set_roughness(1.0h);
}
