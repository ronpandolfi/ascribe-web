---
name: bundling-meshes
description: Use when baking an ascribe-web bundle from a mesh (.stl), choosing a mesh shader, or when a mesh bundle renders invisible, black, flat grey, dark, or inside-out in the viewer.
---

# Baking ascribe-web mesh bundles

## Bake

```powershell
.venv\Scripts\ascribe-bundle build part.stl --shader pearl --story story.md --title "..." -o out/
.venv\Scripts\ascribe-bundle inspect out/     # validates; prints vertex/index/normal counts
```

Binary and ASCII STL are both detected. The bundler welds duplicate vertices and computes smooth
per-vertex normals; the viewer centres the mesh and scales its longest side to 1 m, so file
units don't matter.

**Always pass `--shader`.** The default, `glass`, is invisible on the viewer's black background.

## Shaders (rendered on the torus-knot demo)

| shader | result |
|---|---|
| `pearl` | works: opaque, iridescent. Best default |
| `crystal` | works: translucent violet, shows self-overlap |
| `hologram` | works: unshaded orange with scan lines |
| `glass` (default), `jello` | invisible: transparent over a black background |
| `edges` | renders black |
| `brick`, `holographic`, `water` | flat grey / specks: they sample `UV`, and mesh envelopes have no UVs |

Shader is bake-time only: no picker in the settings panel, and edit mode preserves the
manifest's `display.shader`. Change it by rebaking or editing `manifest.json`. The
Gamma/Opacity/Quality sliders do nothing on a mesh.

## Flags that matter and don't

- `--flip-normals` reverses triangle winding. A normal (counter-clockwise) STL renders correctly
  **without** it. Use it only if the mesh looks dark or you see its inside through the near wall.
  Test both before concluding it is needed.
- `--dtype`, `--max-dim`, `--smooth`, `--window`, `--colormap*`, `--gamma` are **silently
  ignored** for meshes. There is no decimation: payload is ~24 B/vertex + 12 B/triangle. If the
  bundle is too big, simplify the mesh in an external tool (e.g. Blender's Decimate) first.

Shows nothing at all, whatever the shader? Run `inspect`: an STL that parses to zero triangles
bakes without error, and a `vertex_count` of 0 means the file is the problem.

## Demo and comparison

`demo/gen_knot.py out.stl` writes a smooth, watertight (2,3) torus knot. The Pages deploy bakes it
as `?bundle=knot` (pearl) and `?bundle=knot_<shader>` for every shader. Use it to tell "my
mesh is bad" from "this shader is broken": if the knot looks wrong too, it's the shader.

To render a mesh without a browser, use `viewer/tools/shader_probe.gd` (see bundling-volumes)
with a farther view, e.g. `--view=0.6,0.5,2.2`.

## Preview and publish

Same as volumes: `ascribe-bundle serve build\web`, open `index.html?bundle=<dir>`; publish by
committing under `demo/` (or generating in CI) and staging in `.github/workflows/pages.yml`.
