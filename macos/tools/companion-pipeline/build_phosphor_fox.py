#!/usr/bin/env python3
"""Build the Phosphor Fox GLB — the website's hero look, made real in Blender.

m1k3.app renders its fox as a dark body plus an *additive glowing wireframe shell*
(`site/index.html` -> `phosphorise()`): a see-through triangle lattice you can look
straight through to the far legs. The Mac app's `.phosphor` shading style is a
different animal — a fresnel rim-glow (`M1K3App/Phosphor.metal`), which lights the
silhouette but has no interior lattice. So site and app never matched.

A shader cannot close that gap honestly. A RealityKit surface shader only draws on
front faces over an opaque body, so the see-through quality — the thing that makes
the site read as a wireframe sculpture rather than a glowing blob — is unreachable.
(`CompanionShadingStyle` notes the same wall from the other side: a true interior
wireframe would need a baked barycentric attribute.) So we bake the lattice as REAL
GEOMETRY here, once, and the app needs no shader at all: `.off` (baked) shading
reproduces the site exactly.

Two non-obvious steps carry the whole thing:

1. **Weld before wireframing.** The Khronos Fox GLB is a triangle *soup* — 1728
   verts / 1728 edges for 576 tris, i.e. every triangle owns its 3 corners (it is
   authored flat-shaded, so no corner can be shared). Running the Wireframe
   modifier on that gives doubled tubes along every shared edge and gaps at the
   seams. Merging by distance restores a closed manifold (V-E+F == 2, 864 unique
   edges) so the lattice is clean. The duplicate corners are co-located copies of
   ONE original vertex, so their skin weights are identical — merging can never
   blend two different influences.

2. **Wireframe BEFORE Armature in the stack.** The Wireframe modifier interpolates
   vertex groups onto the tube geometry, so the armature then deforms the lattice
   along with the body — one skeleton, two skinned meshes. glTF export applies
   modifiers while deliberately excluding armatures, so the tubes bake into real
   geometry and the skinning survives.

Output: a GLB with `fox` (dark body) + `fox_wire` (emissive lattice), one shared
skeleton named `root`, and the three Khronos clips (Survey/Walk/Run) at their real
durations — no `--retime` needed. Feed it to `export_clips.py` to get the per-clip
USDZs the app loads.

Usage (Blender 4.4+):

  /Applications/Blender.app/Contents/MacOS/Blender -b -P build_phosphor_fox.py -- \
      <source Fox.glb> <out PhosphorFox.glb> [--thickness 0.30] [--colour 0.91,0.91,0.91]

Defaults reproduce the site: wire 0xe8e8e8, body 0x111111 (roughness .55 / metal
.25). `--colour 0.45,1.0,0.72` bakes `PhosphorTreatment.calm` instead — M1K3's
resting phosphor green — if you want the app's palette rather than the site's.

Signed: Kev + claude-opus-5, 2026-07-26, Confidence 0.9 (the weld arithmetic and
the deform-survives-Wireframe claim are both verified in-run and printed as gates:
Euler V-E+F and a posed-centroid delta that must exceed zero; the GLB round-trip
was verified from the GLB's own JSON — two meshes, emissiveFactor, three
animations — and the resulting USDZs passed `rkprobe --tick` 3/3 MOVES. The
on-screen result in RealityKit is verify-at-⌘R, as ever). Prior: Unknown.
"""

from __future__ import annotations

import sys
from typing import Sequence

import bpy
from mathutils import Vector

# The site's palette (site/index.html -> phosphorise()).
SITE_WIRE = (0.91, 0.91, 0.91)  # 0xe8e8e8
SITE_BODY = (0.067, 0.067, 0.067)  # 0x111111
BODY_ROUGHNESS = 0.55
BODY_METALLIC = 0.25
DEFAULT_THICKNESS = 0.30  # world units on the Fox's ~163-unit length: a hairline


def _args(argv: Sequence[str]) -> tuple[str, str, float, tuple[float, float, float]]:
    if "--" not in argv:
        raise SystemExit("usage: blender -b -P build_phosphor_fox.py -- <in.glb> <out.glb> [opts]")
    rest = list(argv[argv.index("--") + 1 :])
    if len(rest) < 2:
        raise SystemExit("usage: ... -- <in.glb> <out.glb> [--thickness N] [--colour r,g,b]")
    src, dst = rest[0], rest[1]
    thickness, colour = DEFAULT_THICKNESS, SITE_WIRE
    i = 2
    while i < len(rest):
        if rest[i] == "--thickness":
            thickness = float(rest[i + 1])
            i += 2
        elif rest[i] in ("--colour", "--color"):
            parts = [float(p) for p in rest[i + 1].split(",")]
            if len(parts) != 3:
                raise SystemExit("--colour wants r,g,b (0..1)")
            colour = (parts[0], parts[1], parts[2])
            i += 2
        else:
            raise SystemExit(f"unknown option {rest[i]!r}")
    return src, dst, thickness, colour


def _emissive(name: str, colour: tuple[float, float, float]) -> bpy.types.Material:
    """Pure emission. Strength stays 1.0 so it exports as a plain glTF
    emissiveFactor — above 1.0 needs KHR_materials_emissive_strength, which the
    USD leg of the pipeline is not guaranteed to carry."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*colour, 1.0)
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    return m


def _dark_body(name: str) -> bpy.types.Material:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (*SITE_BODY, 1.0)
    bsdf.inputs["Roughness"].default_value = BODY_ROUGHNESS
    bsdf.inputs["Metallic"].default_value = BODY_METALLIC
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return m


def _weld(mesh: bpy.types.Mesh) -> tuple[int, int, int]:
    import bmesh

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    bm.to_mesh(mesh)
    bm.free()
    return len(mesh.vertices), len(mesh.edges), len(mesh.polygons)


def _centroid(obj: bpy.types.Object, frame: int) -> Vector:
    bpy.context.scene.frame_set(frame)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = ev.to_mesh()
    n = len(me.vertices)
    c = sum((v.co.copy() for v in me.vertices), Vector()) / n if n else Vector()
    ev.to_mesh_clear()
    return c


def main(argv: Sequence[str]) -> int:
    src, dst, thickness, colour = _args(list(argv))

    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)

    mesh_objs = [o for o in bpy.data.objects if o.type == "MESH" and o.vertex_groups]
    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not mesh_objs or not arms:
        print("BUILD-FAIL: need a skinned mesh + an armature in the source GLB")
        return 1
    body, arm = mesh_objs[0], arms[0]

    # Drop unskinned scenery the source ships (the Khronos Fox carries an Icosphere
    # the site never renders).
    for o in [o for o in bpy.data.objects if o.type == "MESH" and not o.vertex_groups]:
        print(f"BUILD-INFO: dropping unskinned extra {o.name!r}")
        bpy.data.objects.remove(o, do_unlink=True)

    # --- the lattice ---
    wire = body.copy()
    wire.data = body.data.copy()
    wire.name = "fox_wire"
    wire.data.name = "fox_wire_mesh"
    bpy.context.scene.collection.objects.link(wire)

    v, e, f = _weld(wire.data)
    euler = v - e + f
    print(f"BUILD-WELD: verts={v} edges={e} polys={f}  Euler(V-E+F)={euler}")
    if euler != 2:
        # Not fatal — an open or multi-shell source can be legitimately != 2 — but
        # on a closed creature it means the weld did not fully stitch the soup.
        print("BUILD-WARN: Euler != 2 — lattice may carry doubled or missing edges")

    wire.modifiers.clear()
    wf = wire.modifiers.new("Wireframe", "WIREFRAME")
    wf.thickness = thickness
    wf.use_replace = True  # lattice only, no solid faces
    wf.use_even_offset = True
    wf.use_relative_offset = False
    wf.use_boundary = True
    am = wire.modifiers.new("Armature", "ARMATURE")
    am.object = arm  # AFTER Wireframe, so the armature deforms the tubes

    wire.data.materials.clear()
    wire.data.materials.append(_emissive("PHOSPHOR_wire", colour))
    body.data.materials.clear()
    body.data.materials.append(_dark_body("PHOSPHOR_body"))

    # --- gate: the lattice must actually deform, not ride along rigid ---
    actions = sorted(bpy.data.actions, key=lambda a: a.name)
    if not actions:
        print("BUILD-FAIL: source GLB has no actions")
        return 1
    probe = max(actions, key=lambda a: a.frame_range[1] - a.frame_range[0])
    if not arm.animation_data:
        arm.animation_data_create()
    arm.animation_data.action = probe
    lo = int(probe.frame_range[0])
    delta = (_centroid(wire, lo + 8) - _centroid(wire, lo)).length
    print(f"BUILD-DEFORM: '{probe.name}' lattice centroid delta over 8 frames = {delta:.4f}"
          f" -> {'MOVES' if delta > 1e-4 else 'FROZEN'}")
    if delta <= 1e-4:
        print("BUILD-FAIL: lattice does not follow the skeleton (vertex groups lost?)")
        return 1

    # --- export ---
    for o in bpy.data.objects:
        o.select_set(False)
    for o in (body, wire, arm):
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm

    bpy.ops.export_scene.gltf(
        filepath=dst,
        export_format="GLB",
        use_selection=True,
        export_apply=True,  # bakes Wireframe; the exporter excludes armatures
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_skins=True,
        export_materials="EXPORT",
        export_yup=True,
    )
    print(f"BUILD-DONE: {dst}  clips={[a.name for a in actions]}  wire_thickness={thickness}"
          f"  wire_colour={colour}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
