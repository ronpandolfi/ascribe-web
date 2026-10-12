---
name: bundling-meshes
description: Use when baking an ascribe-web bundle from a mesh (.stl), choosing or tuning a mesh's look (colour, opacity, shader), or when a mesh bundle renders invisible, black, flat grey, dark, or inside-out in the viewer.
---

# Baking ascribe-web mesh bundles

## Bake

```powershell
.venv\Scripts\ascribe-bundle build part.stl --color '#2a9d8f' --opacity 0.6 --story story.md --title "..." -o out/
.venv\Scripts\ascribe-bundle inspect out/     # validates; prints vertex/index/normal counts
```

Binary and ASCII STL are both detected. The bundler welds duplicate vertices and computes smooth
per-vertex normals; the viewer centres the mesh and scales its longest side to 1 m, so file
units don't matter. **Quote `--color` in PowerShell**: an unquoted `#` starts a comment, and
the flag silently loses its value.

## The look

The default shader, `surface`, is tunable and works on any mesh: lit, two-sided, opaque gold
(`#d4af37`). Its `display` keys are `color`, `opacity`, `roughness`, `metallic`, `rim` (0-1)
and `inner_surfaces`. Only `--color` and `--opacity` have bake flags. Tune the rest live:

```powershell
.venv\Scripts\ascribe-bundle serve build\web --edit    # then ...?bundle=<dir>&edit=1
```

With a mesh staged, the panel shows mesh controls instead of the volume ones (swatches replace
the colour picker in VR). **Save view + settings** writes only the mesh keys.

Translucency (opacity < 1) has two modes. Nearest surface (the default) fades the mesh as one
shell, with no self-sorting errors. **Show inner surfaces** adds every layer (x-ray), so
internal structure shows. It is additive because "over" blending in triangle order breaks up
into speckled triangles wherever layers overlap. Inner surfaces at opacity 1 renders opaque, by
design.

`--shader pearl|crystal|holographic` gives a fixed look and hides the surface controls.
Holographic is self-lit (a mirrored sky gradient plus a rainbow band from a fixed, world-space
key light), so it does not depend on the scene's lighting or background. Old names (`glass`,
`jello`, `edges`, `brick`, `hologram`, `water`) were removed, and a bundle that still names one
renders with `surface`.

Bundles are wound counter-clockwise (the STL convention); the viewer converts to Godot's
clockwise front faces. If a mesh looks inside-out, the file itself is wound backwards: use
`--flip-normals`.

## Flags that matter and don't

- `--flip-normals` reverses triangle winding. A normal (counter-clockwise) STL renders correctly
  **without** it, and two-sided rendering hides most winding problems anyway. Use it only if
  lighting looks inverted.
- `--dtype`, `--max-dim`, `--smooth`, `--window`, `--colormap*`, `--gamma` are **silently
  ignored** for meshes. There is no decimation: payload is ~24 B/vertex + 12 B/triangle. If the
  bundle is too big, simplify the mesh in an external tool (e.g. Blender's Decimate) first.

Shows nothing at all? Run `inspect`: an STL that parses to zero triangles bakes without error,
and a `vertex_count` of 0 means the file is the problem.

## Demo and comparison

`demo/gen_knot.py out.stl` writes a smooth, watertight (2,3) torus knot. The Pages deploy bakes
it as `?bundle=knot`, `?bundle=knot_<shader>` for each shader, and `?bundle=knot_inner`
(opacity 0.4, inner surfaces). If the knot looks wrong too, the fault is in the viewer, not
your mesh.

To render without a browser, use `viewer/tools/shader_probe.gd` (see bundling-volumes) with a
farther view, e.g. `--view=0.6,0.5,2.2`.

## Preview and publish

Same as volumes: `ascribe-bundle serve build\web`, open `index.html?bundle=<dir>`; publish by
committing under `demo/` (or generating in CI) and staging in `.github/workflows/pages.yml`.
