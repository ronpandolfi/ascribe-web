# Tunable mesh surface material — design

Date: 2026-10-12. Status: awaiting review.

## Goal

Mesh bundles should look good with no flags, be tunable live on desktop and in a headset, and
save their look into the bundle through edit mode — the same lifecycle volumes already have.

Today they do none of that. Rendering all nine mesh shaders on the torus-knot demo showed only
`pearl`, `crystal` and `hologram` usable; the CLI default `glass` is invisible on the viewer's
black background, `jello` likewise, `edges` renders black, and `brick`/`holographic`/`water` need
UVs that mesh envelopes do not carry. The settings panel shows volume controls (gamma, opacity,
quality) that do nothing on a mesh, and there is no way to change a mesh's look without
rebaking.

## Decisions (agreed with Ron)

| Question | Decision |
|---|---|
| Material implementation | `StandardMaterial3D` configured from `display` in code — not a hand-written shader |
| Existing shaders | Keep `pearl`, `crystal`, `hologram`; delete the six broken ones |
| Translucency | UI toggle: "nearest surface" (default) or "inner surfaces" |
| Bake-time flags | `--color` and `--opacity` only; everything else via edit mode |
| Colour UI | Full colour picker on desktop; preset swatches in the VR panel |
| Advanced-panel overlap bug | Fixed as the first commit of this work |

Why `StandardMaterial3D`: it is Godot's stock material, already compiled for the Compatibility
(WebGL2) renderer and exercised in XR stereo. Colour, opacity, roughness, metallic and rim are
plain properties, so dragging a slider costs nothing; the inner-surfaces toggle is a change of
cull/transparency mode rather than a second shader to maintain. Accepted costs: toggling
inner-surfaces (or crossing between opaque and transparent) triggers a one-off shader compile,
roughly 100-300 ms on web; and rim lighting can only tint toward the albedo, not take an
arbitrary colour.

## Manifest

A mesh specimen's `display` gains these keys, all optional:

| key | type | default | meaning |
|---|---|---|---|
| `shader` | string | `"surface"` | `surface`, `pearl`, `crystal` or `hologram` |
| `color` | string `#rrggbb` | `"#c8d2e6"` | base colour (surface only) |
| `opacity` | number 0-1 | `1.0` | surface only |
| `roughness` | number 0-1 | `0.5` | surface only |
| `metallic` | number 0-1 | `0.0` | surface only |
| `rim` | number 0-1 | `0.3` | rim-light strength (surface only) |
| `inner_surfaces` | bool | `false` | translucency mode (surface only) |
| `flip_normals` | bool | `false` | unchanged |

`opacity` already exists in the schema for volumes (scales sample alpha, range 0-2). For a mesh
it means surface alpha, 0-1. The key is shared because both mean "how see-through", and each
specimen type only ever reads its own interpretation; the schema keeps the existing
`{"type": "number"}` and range is enforced by the CLI and the UI.

Under `pearl`/`crystal`/`hologram` the surface keys are ignored but preserved (switching back to
`surface` restores them).

**Unknown or retired shader names** (`glass`, `jello`, `edges`, `brick`, `holographic`, `water`,
or anything else) fall back to `surface` with a `push_warning` naming the shader. A manifest that
omits `shader` gets `surface`. This changes how existing bundles that relied on the `glass`
default render: they become visible.

## Material behaviour (`surface`)

Built by a new `MeshSurfaceMaterial` helper (pure function: `display` dict → `StandardMaterial3D`,
plus an `apply(material, display)` that updates properties in place so slider drags do not
allocate).

- Always: `cull_mode = CULL_DISABLED` — both faces drawn. Godot flips the normal for back faces,
  so open meshes (CAD shells, cut isosurfaces) show their inside correctly instead of holes, and
  a backwards-wound STL still looks right in opaque mode. `flip_normals` stays for lighting.
- `albedo_color` = `color` with alpha = `opacity`; `roughness`, `metallic` as given;
  `rim_enabled = rim > 0`, `rim = rim`, `rim_tint = 0.5`.
- **Nearest surface** (`inner_surfaces = false`): opaque when `opacity >= 1`
  (`TRANSPARENCY_DISABLED`); otherwise `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` — the mesh fades as
  one shell and its own overlapping parts never mis-sort.
- **Inner surfaces** (`inner_surfaces = true`): `TRANSPARENCY_ALPHA`, depth draw disabled — every
  layer blends, so internal structure shows through. Triangle order within one mesh is not
  sorted, so dense meshes can shimmer as the view moves; this is the trade the toggle exposes.

To avoid a compile hitch on every slider tick, the transparency mode only changes when `opacity`
crosses 1.0 or the toggle flips, never while dragging within one regime.

## Bundler

- `MESH_SHADERS` becomes `["surface", "pearl", "crystal", "hologram"]`; `--shader` default
  `surface`.
- New `build` flags, mesh only: `--color HEX` (validated `#rrggbb`), `--opacity F` (0-1). Written
  into `display` only when given, so the viewer defaults stay in one place.
- Volume-only flags remain silently ignored for meshes (unchanged); the mesh flags are ignored for
  volumes. `--opacity` does not collide with anything existing on `build`.
- Schema: add `color` (string, `^#[0-9a-fA-F]{6}$`), `roughness`, `metallic`, `rim` (number),
  `inner_surfaces` (boolean).
- Delete `brick`, `glass`, `jello`, `edges`, `holographic`, `water` shaders and their `.tres` /
  `.uid` files from `viewer/shaders/`.

## Settings panel

One `display_settings_panel.tscn`, still instanced twice (desktop canvas, VR viewport).

- New `MeshSection` VBox alongside the existing volume controls. `set_specimen_type(type)` shows
  exactly one: volume (gamma, opacity, quality, Advanced) or mesh.
- Mesh section: shader dropdown (Surface / Pearl / Crystal / Hologram); then, visible only for
  Surface: colour control, Opacity, Roughness, Metallic, Rim sliders, and an "Show inner
  surfaces" checkbox.
- Colour control: desktop uses a `ColorPickerButton`; the VR instance (`is_vr`) shows a row of 8
  preset swatch buttons instead (pale blue-grey default, bone, copper, gold, teal, crimson,
  violet, slate). A manifest colour that matches no swatch shows no swatch selected and is kept
  until one is pressed.
- `get_display()` returns only the keys of the active specimen type. This matters for edit mode:
  `_save_bundle_settings` merges `get_display()` into the specimen's `display`, and today a mesh
  would get every volume key written into its manifest.
- `set_display()` reads the mesh keys and applies the same defaults as the material.
- Desktop and VR panels stay in sync through the existing `display_changed` cross-wiring.

`main.gd` calls `set_specimen_type` on both panels whenever a specimen is staged (including story
pages that pin a different specimen). The motion-adaptive quality code (`apply_display` calls
near main.gd:800 and :877) sends `max_steps`/`step_size`/`lut_substeps`/`lateral_jitter` every
frame regardless of specimen type. That is harmless today only because mesh `apply_display`
ignores everything but `shader`; once it reads surface keys, guard those call sites to volumes so
a mesh never receives a per-frame partial `display`.

`SpecimenStage._stage_mesh` / `apply_display` route `surface` through `MeshSurfaceMaterial` and
keep `_resolve_mesh_material` for the three legacy names.

## Advanced-panel overlap fix (first commit)

Cause: `display_settings_panel.gd:254-255`. The desktop panel is right-anchored with its right
edge at -340 px; the story panel's left edge is at -320 (main.tscn). Opening Advanced keeps
`offset_left` and sets `offset_right = offset_left + 280`, growing the panel rightward to -300 —
20 px into the story panel. Fix: keep `offset_right` fixed and set
`offset_left = offset_right - width`, so the panel grows leftward. The mesh section uses the same
mechanism for its own height.

## Testing

- **pytest:** `--color`/`--opacity` written for meshes and absent when not given; invalid colour
  and out-of-range opacity rejected; `--shader` rejects retired names; schema accepts the new keys
  and rejects a malformed colour.
- **gdUnit:**
  - panel geometry: with Advanced open and closed, the desktop panel's right edge stays left of
    the story panel's left edge (regression test for the overlap fix);
  - `set_specimen_type` shows exactly one section;
  - `get_display()`/`set_display()` round-trip every mesh key, and `get_display()` in mesh mode
    contains no volume keys;
  - `MeshSurfaceMaterial`: opacity 1 → opaque, <1 → depth pre-pass, inner_surfaces → alpha with
    no depth write, cull always disabled;
  - unknown/retired shader name → surface material, with a warning.
- **Render check:** shader_probe renders of the knot at default, opacity 0.4, and opacity 0.4 with
  inner surfaces — looked at, not just generated.
- **Docs:** update README mesh section and shader table, the `bundling-meshes` skill, and the
  `knot_<shader>` deploy loop (now four variants, plus a translucent `knot_inner`).

## Out of scope

UV generation, textures, per-region colouring of multi-part meshes, and an arbitrary-colour rim
light. Live shader picking for volumes is unchanged.
