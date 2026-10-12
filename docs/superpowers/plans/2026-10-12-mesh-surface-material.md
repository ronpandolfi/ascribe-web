# Tunable Mesh Surface Material Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give mesh specimens a tunable, WebXR-safe `surface` material (colour, opacity, roughness, metallic, rim, inner-surfaces toggle), settable at bake time and live in a mesh settings section that replaces the volume controls, saved through edit mode.

**Architecture:** A static helper `MeshSurfaceMaterial` turns a `display` dict into a `StandardMaterial3D`. `SpecimenStage` keeps the mesh's merged display and routes `surface` through the helper, and the three surviving legacy shaders through the existing loader. A code-built `MeshSettingsSection` lives inside `DisplaySettingsPanel`, which shows either it or the volume controls, depending on `set_specimen_type()`. The bundler gains `--color`/`--opacity` and the schema keys.

**Tech Stack:** Godot 4.7 (GDScript, Compatibility renderer, gdUnit4), Python 3.13 bundler (argparse, jsonschema, pytest).

**Spec:** `docs/superpowers/specs/2026-10-12-mesh-surface-material-design.md`

## Global Constraints

- Shader names: exactly `["surface", "pearl", "crystal", "hologram"]`; default `surface`.
- Default colour `#d4af37` (gold). VR swatches in this order: `#d4af37, #c8d2e6, #e3dac9, #b87333, #2a9d8f, #c0392b, #8e44ad, #5d6d7e`.
- Defaults: opacity 1.0, roughness 0.5, metallic 0.0, rim 0.3, inner_surfaces false. All four numbers are clamped to 0–1 on the mesh side.
- Mesh faces: `cull_mode = CULL_DISABLED` always.
- Transparency: opaque if opacity >= 1 (whatever inner_surfaces is); otherwise `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`, or `TRANSPARENCY_ALPHA` with `DEPTH_DRAW_DISABLED` when inner_surfaces is on. Only assign `transparency`/`depth_draw_mode` when the value actually changes, because each assignment recompiles the shader.
- Godot binary (PowerShell): `& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"`. Below it is written as `<godot>`.
- Viewer tests: `<godot> --headless --path viewer -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests --ignoreHeadlessMode`. Pass a single file with `-a res://tests/<file>.gd`.
- After adding any new `class_name` script, run `<godot> --headless --path viewer --import` once, so the global class cache knows it, and commit the generated `.uid` file.
- Bundler tests: `.venv\Scripts\python -m pytest bundler -q`.
- Match the surrounding style: `##` doc comments on public functions, tabs in GDScript, and comments that explain *why*.
- Commit after each task. Messages end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_015mvtRt7HYcTybiRE7oX4iv`.

## Review Focus

1. A story page that switches from a volume to a mesh leaks the volume's `opacity` (range 0–2) into the mesh. The mesh must clamp it to 1, not break. Test in Task 3 (`resolved`).
2. The motion-adaptive code sends a partial display (`max_steps`, ...) every frame. That must never reset a mesh's colour or shader. Test in Task 4.
3. A hand-edited manifest colour that is uppercase, or matches no swatch: show no swatch selected (or the matching one, case-insensitively), and keep the colour on save. Test in Task 5.
4. An invalid colour string in a hand-edited manifest (`"gold"`): the viewer falls back to the default colour and doesn't crash. Test in Task 3.
5. `inner_surfaces` on with opacity 1 must render opaque, with correct occlusion. It must not blend without depth writes. Test in Task 3.

---

### Task 1: Advanced panel grows leftward instead of into the story panel

**Files:**
- Modify: `viewer/scripts/display_settings_panel.gd:248-255`
- Test: `viewer/tests/test_main_scene.gd` (append)

**Interfaces:**
- Produces: `DisplaySettingsPanel._resize_desktop() -> void`. Task 6 extends it.

- [ ] **Step 1: Write the failing test.** Append to `viewer/tests/test_main_scene.gd`:

```gdscript
# Regression: opening Advanced widened the desktop panel by moving its right edge, which pushed
# it 20 px into the story panel beside it. It must grow leftward instead.
func test_advanced_settings_never_overlap_the_story_panel() -> void:
	var main := await _make_main()
	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")
	var story: Control = main.get_node("CanvasLayer/StoryPanel")
	var toggle: Button = panel.get_node("VBox/AdvancedToggle")

	for _i in 3:
		assert_float(panel.get_global_rect().end.x) \
			.is_less_equal(story.get_global_rect().position.x)
		toggle.emit_signal("pressed")
		await get_tree().process_frame
```

- [ ] **Step 2: Run it and confirm it fails.** Run `<godot> --headless --path viewer -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests/test_main_scene.gd --ignoreHeadlessMode`. Expected: `test_advanced_settings_never_overlap_the_story_panel` FAILS, because the panel's end.x is greater than the story panel's position.x.

- [ ] **Step 3: Implement.** In `display_settings_panel.gd`, replace `_on_advanced_toggled` with:

```gdscript
func _on_advanced_toggled() -> void:
	_advanced_open = not _advanced_open
	_advanced_scroll.visible = _advanced_open
	_advanced_toggle.text = "Advanced Settings [-]" if _advanced_open else "Advanced Settings [+]"
	_resize_desktop()


## Sizes the desktop panel to what it is showing. The panel is right-anchored beside the story
## panel, so it grows leftward: widening it by moving its right edge pushed it into the story
## panel. The in-VR instance fills its SubViewport and is left alone.
func _resize_desktop() -> void:
	if is_vr or not (get_parent() is CanvasLayer):
		return
	var width := 280.0 if _advanced_open else 240.0
	var height := 560.0 if _advanced_open else 260.0
	offset_left = offset_right - width
	offset_bottom = offset_top + height
```

- [ ] **Step 4: Run the whole viewer suite.** Expected: all tests pass, including the existing `test_advanced_toggle_expands_and_collapses_scroll`.

- [ ] **Step 5: Commit.** `git add viewer/scripts/display_settings_panel.gd viewer/tests/test_main_scene.gd`, then commit with the message `fix(panel): grow Advanced settings leftward instead of into the story panel`.

---

### Task 2: Bundler — mesh shader list, `--color`, `--opacity`, schema

**Files:**
- Modify: `bundler/src/ascribe_bundle/cli.py` (the `MESH_SHADERS` block at lines 19-29, the mesh `display` branch at lines 75-78, and the `build` argparse options)
- Modify: `bundler/src/ascribe_bundle/manifest.py` (the `display.properties` block)
- Test: `bundler/tests/test_cli.py`, `bundler/tests/test_manifest.py`

**Interfaces:**
- Produces: a mesh specimen `display` of the form `{"shader": str, "color"?: "#rrggbb" (lowercase), "opacity"?: float, "flip_normals"?: true}`.

- [ ] **Step 1: Write the failing tests.** In `bundler/tests/test_cli.py`, change the last assertion of `test_build_mesh_default_shader` from `== "glass"` to:

```python
    display = manifest["specimens"][0]["display"]
    assert display["shader"] == "surface"
    # Unset look parameters stay out of the manifest, so the viewer's defaults live in one place.
    assert "color" not in display and "opacity" not in display
```

Then append:

```python
def _triangle_stl(tmp_path: Path) -> Path:
    stl = tmp_path / "tri.stl"
    stl.write_text("solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n"
                   "   vertex 1 0 0\n   vertex 0 1 0\n  endloop\n endfacet\nendsolid t\n",
                   encoding="utf-8")
    return stl


def test_build_mesh_color_and_opacity(tmp_path: Path):
    out = tmp_path / "out"
    assert main(["build", str(_triangle_stl(tmp_path)), "--color", "#D4AF37",
                 "--opacity", "0.4", "-o", str(out)]) == 0
    display = json.loads((out / "manifest.json").read_text())["specimens"][0]["display"]
    assert display["color"] == "#d4af37"
    assert display["opacity"] == 0.4


@pytest.mark.parametrize("flags", [
    ["--color", "gold"],
    ["--color", "#abc"],
    ["--opacity", "1.5"],
    ["--opacity", "-0.1"],
    ["--shader", "glass"],
])
def test_build_mesh_rejects_bad_look_flags(tmp_path: Path, flags):
    with pytest.raises(SystemExit):
        main(["build", str(_triangle_stl(tmp_path)), *flags, "-o", str(tmp_path / "out")])
```

Add `import pytest` to the top of `test_cli.py` if it is not already there. Append to `bundler/tests/test_manifest.py`:

```python
def _mesh(display):
    return {"id": "m0", "type": "mesh", "data": "specimen_0.bin", "display": display}


def test_validate_accepts_mesh_surface_display():
    m = make_manifest("t", [_mesh({"shader": "surface", "color": "#d4af37", "opacity": 0.4,
                                   "roughness": 0.5, "metallic": 0.0, "rim": 0.3,
                                   "inner_surfaces": True})], [])
    validate_manifest(m)


def test_validate_rejects_malformed_mesh_color():
    m = make_manifest("t", [_mesh({"color": "gold"})], [])
    with pytest.raises(ValueError):
        validate_manifest(m)
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `.venv\Scripts\python -m pytest bundler -q`. Expected failures: the default shader is still `glass`, `--color` and `--opacity` are unrecognised, and `"gold"` is accepted.

- [ ] **Step 3: Implement `cli.py`.** Delete the `MESH_SHADERS = [...]` block that sits between the imports (lines 19-29). Then add `import re` to the stdlib imports, and add this after the last `from .volume import ...` line:

```python
# The tunable `surface` material plus the three legacy looks that render correctly on a mesh.
# The others (glass, jello, edges, brick, holographic, water) were removed: they were invisible
# on the viewer's black background or needed UVs that mesh envelopes do not carry.
MESH_SHADERS = ["surface", "pearl", "crystal", "hologram"]
```

Replace the mesh branch in `build()`:

```python
    if spec_type == "mesh":
        display = {"shader": args.shader}
        # Only what was asked for: unset look parameters fall back to the viewer's defaults.
        if args.color is not None:
            display["color"] = args.color
        if args.opacity is not None:
            display["opacity"] = args.opacity
        if getattr(args, "flip_normals", False):
            display["flip_normals"] = True
```

Add these helpers next to `_alpha_pair`:

```python
def _hex_color(text: str) -> str:
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", text):
        raise argparse.ArgumentTypeError(f"expected a #rrggbb colour, got {text!r}")
    return text.lower()


def _unit_float(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a number, got {text!r}") from None
    if not 0.0 <= value <= 1.0:
        raise argparse.ArgumentTypeError(f"must be between 0 and 1, got {text!r}")
    return value
```

Replace the `--shader` option and add the two new ones after it:

```python
    b.add_argument("--shader", choices=MESH_SHADERS, default="surface",
                   help="mesh material (default: surface, the tunable one; pearl, crystal and "
                        "hologram are fixed looks)")
    b.add_argument("--color", type=_hex_color, default=None, metavar="#RRGGBB",
                   help="mesh base colour for the surface shader (default gold, #d4af37). "
                        "Quote it in PowerShell, where an unquoted # starts a comment")
    b.add_argument("--opacity", type=_unit_float, default=None, metavar="0-1",
                   help="mesh opacity for the surface shader (default 1)")
```

- [ ] **Step 4: Implement `manifest.py`.** In `SCHEMA` → specimens → items → display → properties, after `"flip_normals": {"type": "boolean"},` add:

```python
                            # Mesh `surface` material. `opacity` is shared with volumes and
                            # already declared above.
                            "color": {"type": "string", "pattern": r"^#[0-9a-fA-F]{6}$"},
                            "roughness": {"type": "number"},
                            "metallic": {"type": "number"},
                            "rim": {"type": "number"},
                            "inner_surfaces": {"type": "boolean"},
```

- [ ] **Step 5: Run the bundler suite.** Run `.venv\Scripts\python -m pytest bundler -q`. Expected: all 75 tests pass.

- [ ] **Step 6: Commit.** Use the message `feat(bundler): surface mesh shader default with --color/--opacity`.

---

### Task 3: `MeshSurfaceMaterial` helper

**Files:**
- Create: `viewer/scripts/mesh_surface_material.gd`
- Test: `viewer/tests/test_mesh_surface_material.gd`

**Interfaces:**
- Produces:
  - `const MeshSurfaceMaterial.SHADERS: Array = ["surface", "pearl", "crystal", "hologram"]`
  - `const MeshSurfaceMaterial.DEFAULT_COLOR: String = "#d4af37"`
  - `static func shader_name(display: Dictionary) -> String`: the normalised name. An unknown name returns `"surface"` with a warning.
  - `static func resolved(display: Dictionary) -> Dictionary`: returns the keys `color` (String), `opacity`, `roughness`, `metallic`, `rim` (float, clamped 0–1) and `inner_surfaces` (bool), with defaults filled in.
  - `static func build(display: Dictionary) -> StandardMaterial3D`
  - `static func apply(mat: StandardMaterial3D, display: Dictionary) -> void`

- [ ] **Step 1: Write the failing test.** Create `viewer/tests/test_mesh_surface_material.gd`:

```gdscript
extends GdUnitTestSuite


func test_defaults_are_an_opaque_two_sided_gold() -> void:
	var mat := MeshSurfaceMaterial.build({})
	assert_int(mat.cull_mode).is_equal(BaseMaterial3D.CULL_DISABLED)
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#d4af37")
	assert_float(mat.albedo_color.a).is_equal_approx(1.0, 0.001)
	assert_float(mat.roughness).is_equal_approx(0.5, 0.001)
	assert_float(mat.metallic).is_equal_approx(0.0, 0.001)
	assert_bool(mat.rim_enabled).is_true()
	assert_float(mat.rim).is_equal_approx(0.3, 0.001)


func test_translucent_nearest_surface_uses_depth_prepass() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4})
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	assert_float(mat.albedo_color.a).is_equal_approx(0.4, 0.001)


func test_inner_surfaces_blend_every_layer_without_depth_writes() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4, "inner_surfaces": true})
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_int(mat.depth_draw_mode).is_equal(BaseMaterial3D.DEPTH_DRAW_DISABLED)


# Blending without depth writes at full opacity would draw far surfaces over near ones.
func test_inner_surfaces_at_full_opacity_stays_opaque() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 1.0, "inner_surfaces": true})
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_int(mat.depth_draw_mode).is_equal(BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY)


func test_apply_updates_in_place() -> void:
	var mat := MeshSurfaceMaterial.build({})
	MeshSurfaceMaterial.apply(mat, {"color": "#2a9d8f", "roughness": 0.9, "rim": 0.0})
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#2a9d8f")
	assert_float(mat.roughness).is_equal_approx(0.9, 0.001)
	assert_bool(mat.rim_enabled).is_false()


# A story page moving from a volume to a mesh carries the volume's opacity (range 0-2) along.
func test_out_of_range_values_are_clamped() -> void:
	var s := MeshSurfaceMaterial.resolved({"opacity": 1.7, "roughness": -1.0, "rim": 3.0})
	assert_float(s["opacity"]).is_equal(1.0)
	assert_float(s["roughness"]).is_equal(0.0)
	assert_float(s["rim"]).is_equal(1.0)


func test_invalid_color_falls_back_to_default() -> void:
	var mat := MeshSurfaceMaterial.build({"color": "gold"})
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#d4af37")


func test_shader_name_normalises_and_falls_back() -> void:
	assert_str(MeshSurfaceMaterial.shader_name({})).is_equal("surface")
	assert_str(MeshSurfaceMaterial.shader_name({"shader": " Crystal "})).is_equal("crystal")
	assert_str(MeshSurfaceMaterial.shader_name({"shader": "glass"})).is_equal("surface")
```

- [ ] **Step 2: Run the test and confirm it fails.** Run with `-a res://tests/test_mesh_surface_material.gd`. Expected: FAIL or a parse error, because `MeshSurfaceMaterial` doesn't exist yet.

- [ ] **Step 3: Implement.** Create `viewer/scripts/mesh_surface_material.gd`:

```gdscript
## Builds and updates the tunable `surface` material for mesh specimens from a bundle's
## `display` dict. It is a StandardMaterial3D rather than a hand-written shader: the stock
## material is already compiled for the Compatibility (WebGL2) renderer and exercised in XR
## stereo, and every look parameter is a plain property, so slider drags cost nothing.
class_name MeshSurfaceMaterial
extends RefCounted

## Mesh shader names a bundle may use. `surface` is this material; the rest are fixed-look
## shaders under res://shaders/.
const SHADERS := ["surface", "pearl", "crystal", "hologram"]
const DEFAULT_COLOR := "#d4af37"


## The shader `display` asks for, normalised. Retired or unknown names (glass, brick, ...) fall
## back to `surface` so that an old bundle renders visibly instead of not at all.
static func shader_name(display: Dictionary) -> String:
	var shader := str(display.get("shader", "surface")).to_lower().strip_edges()
	if shader.is_empty():
		return "surface"
	if shader in SHADERS:
		return shader
	push_warning("mesh shader '%s' is not available; using 'surface'" % [shader])
	return "surface"


## `display`'s look parameters with defaults filled in and numbers clamped to 0-1. The single
## source of defaults for the material and the settings panel alike.
static func resolved(display: Dictionary) -> Dictionary:
	return {
		"color": str(display.get("color", DEFAULT_COLOR)),
		"opacity": clampf(float(display.get("opacity", 1.0)), 0.0, 1.0),
		"roughness": clampf(float(display.get("roughness", 0.5)), 0.0, 1.0),
		"metallic": clampf(float(display.get("metallic", 0.0)), 0.0, 1.0),
		"rim": clampf(float(display.get("rim", 0.3)), 0.0, 1.0),
		"inner_surfaces": bool(display.get("inner_surfaces", false)),
	}


## A new material configured from `display`.
static func build(display: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# Both faces, always: open meshes (CAD shells, cut isosurfaces) show their inside instead of
	# holes, and Godot flips the normal for back faces so they light correctly.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.rim_tint = 0.5
	apply(mat, display)
	return mat


## Updates `mat` in place from `display`.
static func apply(mat: StandardMaterial3D, display: Dictionary) -> void:
	var s := resolved(display)
	var color := Color.from_string(s["color"], Color.from_string(DEFAULT_COLOR, Color.WHITE))
	color.a = s["opacity"]
	mat.albedo_color = color
	mat.roughness = s["roughness"]
	mat.metallic = s["metallic"]
	mat.rim_enabled = s["rim"] > 0.0
	mat.rim = s["rim"]

	var transparency := BaseMaterial3D.TRANSPARENCY_DISABLED
	if s["opacity"] < 1.0:
		transparency = (BaseMaterial3D.TRANSPARENCY_ALPHA if s["inner_surfaces"]
			else BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	var depth := (BaseMaterial3D.DEPTH_DRAW_DISABLED
		if transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
		else BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY)
	# Each assignment recompiles the shader -- a visible hitch on web -- so only touch these when
	# the regime actually changes, never on every slider tick.
	if mat.transparency != transparency:
		mat.transparency = transparency
	if mat.depth_draw_mode != depth:
		mat.depth_draw_mode = depth
```

- [ ] **Step 4: Import, then run the test.** Run `<godot> --headless --path viewer --import`, then run the test file. Expected: PASS for all 8 tests.

- [ ] **Step 5: Commit.** Commit the script, its `.uid` and the test (plus the test's `.uid`) with the message `feat(viewer): MeshSurfaceMaterial for tunable mesh look`.

---

### Task 4: `SpecimenStage` uses the surface material; retire the broken shaders

**Files:**
- Modify: `viewer/scripts/specimen_stage.gd` (`clear`, `apply_display`, `_stage_mesh`, `_resolve_mesh_material`)
- Delete: `viewer/shaders/{glass,jello,edges,brick,holographic,water}.gdshader` and their `.gdshader.uid` files, plus `viewer/shaders/jello.tres` and `viewer/shaders/water.tres`
- Test: `viewer/tests/test_specimen_stage.gd` (replace the three mesh tests at lines 196-257)

**Interfaces:**
- Consumes: `MeshSurfaceMaterial.shader_name`, `.build`, `.apply` (Task 3).
- Produces: after `stage()`, a mesh's override material is a `StandardMaterial3D` (surface) or a `ShaderMaterial` carrying `get_meta("mesh_shader")` (legacy). `apply_display(partial)` merges into the stage's mesh display.

- [ ] **Step 1: Confirm nothing else references the shaders being deleted.** Run `git grep -n -E "glass|jello|edges\.gd|brick|holographic|water" -- viewer ':!viewer/shaders'`. Expected: hits only in `viewer/tests/test_specimen_stage.gd`, `viewer/scripts/specimen_stage.gd` and possibly `export_presets.cfg`. Show the output in the report.

- [ ] **Step 2: Write the failing tests.** In `viewer/tests/test_specimen_stage.gd`, replace `test_stage_mesh_applies_glass_shader_by_default`, `test_stage_mesh_applies_specified_shader` and `test_apply_display_updates_mesh_shader` with:

```gdscript
func _staged_mesh(stage: SpecimenStage) -> MeshInstance3D:
	for child in stage.get_children():
		if child is MeshInstance3D:
			return child
	return null


func test_stage_mesh_uses_the_surface_material_by_default() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("mesh_specimen_0", _build_test_mesh_data(), {})

	assert_that(stage.current_id).is_equal("mesh_specimen_0")
	assert_that(_count_mesh_children(stage)).is_equal(1)
	var mat: Material = _staged_mesh(stage).get_surface_override_material(0)
	assert_that(mat is StandardMaterial3D).is_true()
	assert_str("#" + (mat as StandardMaterial3D).albedo_color.to_html(false)).is_equal("#d4af37")


func test_stage_mesh_applies_a_legacy_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("mesh_specimen_crystal", _build_test_mesh_data(), {"shader": "crystal"})

	var mat: Material = _staged_mesh(stage).get_surface_override_material(0)
	assert_that(mat is ShaderMaterial).is_true()
	assert_that((mat as ShaderMaterial).shader.resource_path).is_equal("res://shaders/crystal.gdshader")


func test_retired_shader_names_render_with_surface() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("old", _build_test_mesh_data(), {"shader": "glass"})
	assert_that(_staged_mesh(stage).get_surface_override_material(0) is StandardMaterial3D).is_true()


func test_apply_display_switches_between_legacy_and_surface() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {"shader": "crystal"})
	var mesh := _staged_mesh(stage)

	stage.apply_display({"shader": "hologram"})
	var holo: ShaderMaterial = mesh.get_surface_override_material(0)
	assert_that(holo.shader.resource_path).is_equal("res://shaders/hologram.gdshader")

	stage.apply_display({"shader": "surface", "color": "#2a9d8f"})
	var surf: StandardMaterial3D = mesh.get_surface_override_material(0)
	assert_str("#" + surf.albedo_color.to_html(false)).is_equal("#2a9d8f")


func test_surface_sliders_update_the_material_in_place() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {})
	var mesh := _staged_mesh(stage)
	var before: Material = mesh.get_surface_override_material(0)

	stage.apply_display({"opacity": 0.4})
	var after: StandardMaterial3D = mesh.get_surface_override_material(0)
	assert_that(after).is_same(before)
	assert_int(after.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)


# The motion-adaptive quality code sends a partial display every frame; on a mesh it must not
# reset anything a bundle or the panel set.
func test_partial_volume_display_leaves_the_mesh_look_alone() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {"color": "#c0392b", "opacity": 0.5})

	stage.apply_display({"max_steps": 64, "step_size": 0.01, "lut_substeps": 1})
	var mat: StandardMaterial3D = _staged_mesh(stage).get_surface_override_material(0)
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#c0392b")
	assert_float(mat.albedo_color.a).is_equal_approx(0.5, 0.001)
```

- [ ] **Step 3: Run the tests and confirm they fail.** Run with `-a res://tests/test_specimen_stage.gd`. Expected: the new mesh tests FAIL, because the material is still a glass `ShaderMaterial`.

- [ ] **Step 4: Implement.** In `specimen_stage.gd`, add the following below `var current_id: String = ""`:

```gdscript
## Keys that change how a staged mesh looks. Anything else in a display dict (volume quality
## settings the motion-adaptive code sends every frame) is ignored for meshes.
const MESH_DISPLAY_KEYS := ["shader", "color", "opacity", "roughness", "metallic", "rim",
	"inner_surfaces"]

## The staged mesh's display, accumulated across apply_display() calls, so a partial update
## (one slider) never resets the rest of the look.
var _mesh_display: Dictionary = {}
```

In `clear()`, add `_mesh_display = {}` after `current_id = ""`. Replace the `apply_display` body and its doc comment:

```gdscript
## Applies display settings to the currently staged specimen.
## For volumes: shader uniforms (gamma, opacity, gradient, quality, ...).
## For meshes: merges the look keys into the mesh's display and re-applies its material.
func apply_display(display: Dictionary) -> void:
	var mesh_instance := _current_mesh_instance()
	if mesh_instance == null:
		return
	var mat: Material = mesh_instance.get_surface_override_material(0)
	if mat is ShaderMaterial and (mat as ShaderMaterial).shader == VOLUME_SHADER:
		_apply_display_to_material(mat as ShaderMaterial, display)
		return
	var changed := false
	for key in MESH_DISPLAY_KEYS:
		if display.has(key) and _mesh_display.get(key) != display[key]:
			_mesh_display[key] = display[key]
			changed = true
	if changed:
		_apply_mesh_material(mesh_instance)
```

In `_stage_mesh`, replace these lines:

```gdscript
	var shader_name: String = str(display.get("shader", "glass"))
	var mat := _resolve_mesh_material(shader_name)
	if mat != null:
		mesh_instance.set_surface_override_material(0, mat)

	add_child(mesh_instance)
```

with:

```gdscript
	add_child(mesh_instance)
	_mesh_display = display.duplicate()
	_apply_mesh_material(mesh_instance)
```

Add this new function above `_resolve_mesh_material`:

```gdscript
## Puts the material `_mesh_display` asks for on `mesh_instance`: the tunable surface material
## (updated in place when it is already there) or one of the fixed-look legacy shaders.
func _apply_mesh_material(mesh_instance: MeshInstance3D) -> void:
	var shader := MeshSurfaceMaterial.shader_name(_mesh_display)
	var current: Material = mesh_instance.get_surface_override_material(0)
	if shader == "surface":
		if current is StandardMaterial3D:
			MeshSurfaceMaterial.apply(current as StandardMaterial3D, _mesh_display)
		else:
			mesh_instance.set_surface_override_material(0, MeshSurfaceMaterial.build(_mesh_display))
		return
	if current != null and current.get_meta("mesh_shader", "") == shader:
		return
	var mat := _resolve_mesh_material(shader)
	if mat != null:
		mat.set_meta("mesh_shader", shader)
		mesh_instance.set_surface_override_material(0, mat)
```

Replace `_resolve_mesh_material` with:

```gdscript
## Loads a legacy mesh shader by name, preferring a tuned `.tres` material over the bare shader.
func _resolve_mesh_material(shader_name: String) -> Material:
	var tres_path := "res://shaders/" + shader_name + ".tres"
	var shader_path := "res://shaders/" + shader_name + ".gdshader"
	if ResourceLoader.exists(tres_path):
		var res := load(tres_path)
		if res is Material:
			return (res as Material).duplicate()
	if ResourceLoader.exists(shader_path):
		var sh := load(shader_path)
		if sh is Shader:
			var sm := ShaderMaterial.new()
			sm.shader = sh
			return sm
	push_error("SpecimenStage: mesh shader '%s' failed to load" % [shader_name])
	return null
```

- [ ] **Step 5: Delete the retired shaders.** Run `git rm viewer/shaders/glass.gdshader viewer/shaders/glass.gdshader.uid viewer/shaders/jello.gdshader viewer/shaders/jello.gdshader.uid viewer/shaders/jello.tres viewer/shaders/edges.gdshader viewer/shaders/edges.gdshader.uid viewer/shaders/brick.gdshader viewer/shaders/brick.gdshader.uid viewer/shaders/holographic.gdshader viewer/shaders/holographic.gdshader.uid viewer/shaders/water.gdshader viewer/shaders/water.gdshader.uid viewer/shaders/water.tres`.

- [ ] **Step 6: Import and run the whole viewer suite.** Run `<godot> --headless --path viewer --import`, then the full suite. Expected: everything passes, and the import reports no missing-dependency errors.

- [ ] **Step 7: Commit.** Use the message `feat(viewer): surface material for meshes; retire six broken mesh shaders`.

---

### Task 5: `MeshSettingsSection` UI

**Files:**
- Create: `viewer/scripts/mesh_settings_section.gd`
- Test: `viewer/tests/test_mesh_settings_section.gd`

**Interfaces:**
- Consumes: `MeshSurfaceMaterial.SHADERS`, `.DEFAULT_COLOR`, `.shader_name`, `.resolved` (Task 3).
- Produces: `class_name MeshSettingsSection extends VBoxContainer` with:
  - `signal changed`
  - `func get_display() -> Dictionary`, which returns exactly the keys `shader, color, opacity, roughness, metallic, rim, inner_surfaces`
  - `func set_display(display: Dictionary) -> void`, which reads only the keys present and never emits
  - `func set_vr(vr: bool) -> void`
  - Child nodes: `Shader` (OptionButton); `Surface/Color` (ColorPickerButton); `Surface/Swatches/Swatch_<hex>` (Button); `Surface/Opacity`, `Surface/Roughness`, `Surface/Metallic`, `Surface/Rim` (HSlider); `Surface/InnerSurfaces` (CheckBox).

- [ ] **Step 1: Write the failing test.** Create `viewer/tests/test_mesh_settings_section.gd`:

```gdscript
extends GdUnitTestSuite


func _make() -> MeshSettingsSection:
	var section: MeshSettingsSection = auto_free(MeshSettingsSection.new())
	add_child(section)
	return section


func test_defaults_match_the_material() -> void:
	var d := _make().get_display()
	assert_str(d["shader"]).is_equal("surface")
	assert_str(d["color"]).is_equal("#d4af37")
	assert_float(d["opacity"]).is_equal_approx(1.0, 0.001)
	assert_float(d["roughness"]).is_equal_approx(0.5, 0.001)
	assert_float(d["metallic"]).is_equal_approx(0.0, 0.001)
	assert_float(d["rim"]).is_equal_approx(0.3, 0.001)
	assert_bool(d["inner_surfaces"]).is_false()
	assert_int(d.size()).is_equal(7)


func test_set_display_round_trips_without_emitting() -> void:
	var section := _make()
	var seen := [0]
	section.changed.connect(func(): seen[0] += 1)
	var wanted := {"shader": "surface", "color": "#2a9d8f", "opacity": 0.4, "roughness": 0.8,
		"metallic": 0.6, "rim": 0.0, "inner_surfaces": true}
	section.set_display(wanted)
	var got := section.get_display()
	for key in wanted:
		if wanted[key] is float:
			assert_float(got[key]).is_equal_approx(wanted[key], 0.001)
		else:
			assert_that(got[key]).is_equal(wanted[key])
	assert_int(seen[0]).is_equal(0)


func test_moving_a_slider_emits_changed() -> void:
	var section := _make()
	var seen := [0]
	section.changed.connect(func(): seen[0] += 1)
	(section.get_node("Surface/Roughness") as HSlider).value = 0.9
	assert_int(seen[0]).is_equal(1)
	assert_float(section.get_display()["roughness"]).is_equal_approx(0.9, 0.001)


func test_legacy_shader_hides_the_surface_controls() -> void:
	var section := _make()
	section.set_display({"shader": "crystal"})
	assert_bool((section.get_node("Surface") as Control).visible).is_false()
	section.set_display({"shader": "surface"})
	assert_bool((section.get_node("Surface") as Control).visible).is_true()


func test_vr_swaps_the_picker_for_swatches() -> void:
	var section := _make()
	assert_bool((section.get_node("Surface/Color") as Control).visible).is_true()
	assert_bool((section.get_node("Surface/Swatches") as Control).visible).is_false()
	section.set_vr(true)
	assert_bool((section.get_node("Surface/Color") as Control).visible).is_false()
	assert_bool((section.get_node("Surface/Swatches") as Control).visible).is_true()


func test_pressing_a_swatch_sets_the_colour() -> void:
	var section := _make()
	section.set_vr(true)
	(section.get_node("Surface/Swatches/Swatch_c0392b") as Button).emit_signal("pressed")
	assert_str(section.get_display()["color"]).is_equal("#c0392b")


# A hand-edited manifest colour that matches no swatch must survive being shown in VR.
func test_unmatched_colour_selects_no_swatch_and_is_kept() -> void:
	var section := _make()
	section.set_vr(true)
	section.set_display({"color": "#123456"})
	for b in section.get_node("Surface/Swatches").get_children():
		assert_bool((b as Button).button_pressed).is_false()
	assert_str(section.get_display()["color"]).is_equal("#123456")
	section.set_display({"color": "#C0392B"})
	assert_bool((section.get_node("Surface/Swatches/Swatch_c0392b") as Button).button_pressed).is_true()
```

- [ ] **Step 2: Run the test and confirm it fails.** Run with `-a res://tests/test_mesh_settings_section.gd`. Expected: FAIL, because the class doesn't exist yet.

- [ ] **Step 3: Implement.** Create `viewer/scripts/mesh_settings_section.gd`:

```gdscript
## The mesh half of the display settings panel: a shader picker and, for the tunable `surface`
## shader, colour, opacity, roughness, metallic, rim and the inner-surfaces toggle. Built in code
## and owned by DisplaySettingsPanel, which shows either this or the volume controls.
class_name MeshSettingsSection
extends VBoxContainer

signal changed

const SHADER_LABELS := {"surface": "Surface", "pearl": "Pearl", "crystal": "Crystal",
	"hologram": "Hologram"}
## Colour presets for the in-VR panel, where a colour picker is fiddly to drive with a laser
## pointer. Gold first: it is the default.
const SWATCHES := ["#d4af37", "#c8d2e6", "#e3dac9", "#b87333", "#2a9d8f", "#c0392b", "#8e44ad",
	"#5d6d7e"]
const SLIDERS := [
	["opacity", "Opacity: %.2f"],
	["roughness", "Roughness: %.2f"],
	["metallic", "Metallic: %.2f"],
	["rim", "Rim light: %.2f"],
]

var _shader_option: OptionButton
var _surface_box: VBoxContainer
var _color_picker: ColorPickerButton
var _swatch_row: HBoxContainer
var _inner_check: CheckBox
var _sliders := {}  # key -> HSlider
var _labels := {}   # key -> [Label, format]
var _color: String = MeshSurfaceMaterial.DEFAULT_COLOR


func _init() -> void:
	name = "MeshSection"

	_shader_option = OptionButton.new()
	_shader_option.name = "Shader"
	for key in MeshSurfaceMaterial.SHADERS:
		_shader_option.add_item(SHADER_LABELS[key])
	_shader_option.item_selected.connect(func(_i: int) -> void:
		_sync_surface_visibility()
		changed.emit()
	)
	add_child(_shader_option)

	_surface_box = VBoxContainer.new()
	_surface_box.name = "Surface"
	add_child(_surface_box)

	_color_picker = ColorPickerButton.new()
	_color_picker.name = "Color"
	_color_picker.custom_minimum_size = Vector2(0, 28)
	_color_picker.edit_alpha = false
	_color_picker.color_changed.connect(func(c: Color) -> void:
		_color = "#" + c.to_html(false)
		_sync_swatches()
		changed.emit()
	)
	_surface_box.add_child(_color_picker)

	_swatch_row = HBoxContainer.new()
	_swatch_row.name = "Swatches"
	_swatch_row.visible = false
	for hex in SWATCHES:
		_swatch_row.add_child(_make_swatch(hex))
	_surface_box.add_child(_swatch_row)

	for spec in SLIDERS:
		_add_slider(spec[0], spec[1])

	_inner_check = CheckBox.new()
	_inner_check.name = "InnerSurfaces"
	_inner_check.text = "Show inner surfaces"
	_inner_check.toggled.connect(func(_p: bool) -> void: changed.emit())
	_surface_box.add_child(_inner_check)

	var defaults := MeshSurfaceMaterial.resolved({})
	defaults["shader"] = "surface"
	set_display(defaults)


## The mesh look as a display dict: always exactly these seven keys.
func get_display() -> Dictionary:
	var d := {
		"shader": MeshSurfaceMaterial.SHADERS[_shader_option.selected],
		"color": _color,
		"inner_surfaces": _inner_check.button_pressed,
	}
	for key in _sliders:
		d[key] = (_sliders[key] as HSlider).value
	return d


## Shows the keys present in `display` without emitting `changed`; absent keys keep their value.
func set_display(display: Dictionary) -> void:
	if display.has("shader"):
		_shader_option.select(MeshSurfaceMaterial.SHADERS.find(
			MeshSurfaceMaterial.shader_name(display)))
	if display.has("color"):
		_color = str(display["color"]).to_lower()
		_color_picker.color = Color.from_string(_color, _color_picker.color)
	var s := MeshSurfaceMaterial.resolved(display)
	for key in _sliders:
		if display.has(key):
			(_sliders[key] as HSlider).set_value_no_signal(s[key])
			_refresh_label(key)
	if display.has("inner_surfaces"):
		_inner_check.set_pressed_no_signal(s["inner_surfaces"])
	_sync_surface_visibility()
	_sync_swatches()


## In a headset, offers preset swatches in place of the colour picker.
func set_vr(vr: bool) -> void:
	_color_picker.visible = not vr
	_swatch_row.visible = vr


func _add_slider(key: String, fmt: String) -> void:
	var label := Label.new()
	label.name = key.capitalize() + "Label"
	var slider := HSlider.new()
	slider.name = key.capitalize()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	_sliders[key] = slider
	_labels[key] = [label, fmt]
	slider.value_changed.connect(func(_v: float) -> void:
		_refresh_label(key)
		changed.emit()
	)
	_surface_box.add_child(label)
	_surface_box.add_child(slider)


func _refresh_label(key: String) -> void:
	var entry: Array = _labels[key]
	(entry[0] as Label).text = (entry[1] as String) % (_sliders[key] as HSlider).value


func _make_swatch(hex: String) -> Button:
	var b := Button.new()
	b.name = "Swatch_" + hex.substr(1)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(44, 44)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.from_string(hex, Color.WHITE)
	var selected := normal.duplicate() as StyleBoxFlat
	selected.set_border_width_all(3)
	selected.border_color = Color.WHITE
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", selected)
	b.add_theme_stylebox_override("hover_pressed", selected)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func() -> void:
		_color = hex
		_color_picker.color = Color.from_string(hex, _color_picker.color)
		_sync_swatches()
		changed.emit()
	)
	return b


func _sync_surface_visibility() -> void:
	_surface_box.visible = _shader_option.selected == 0


## Marks the swatch matching the current colour, if any. A colour that matches none is kept as is.
func _sync_swatches() -> void:
	for b in _swatch_row.get_children():
		(b as Button).set_pressed_no_signal(b.name == "Swatch_" + _color.substr(1))
```

- [ ] **Step 4: Import, then run the test.** Run `<godot> --headless --path viewer --import`, then the test file. Expected: all 7 tests PASS.

- [ ] **Step 5: Commit.** Commit the script, its test and their `.uid` files with the message `feat(viewer): MeshSettingsSection with picker/swatches and surface sliders`.

---

### Task 6: `DisplaySettingsPanel` shows either the mesh section or the volume controls

**Files:**
- Modify: `viewer/scripts/display_settings_panel.gd` (var block, `_ready`, `_resize_desktop`, `get_display`, `set_display`, `set_exit_vr_visible`, plus a new `set_specimen_type`)
- Test: `viewer/tests/test_display_settings_panel.gd` (append)

**Interfaces:**
- Consumes: `MeshSettingsSection` (Task 5); `_resize_desktop` (Task 1).
- Produces: `DisplaySettingsPanel.set_specimen_type(type: String) -> void`, where `type` is `"mesh"` or `"volume"`. In mesh mode `get_display()` returns only the mesh section's keys.

- [ ] **Step 1: Write the failing tests.** Append to `viewer/tests/test_display_settings_panel.gd`:

```gdscript
func test_mesh_mode_shows_only_the_mesh_section() -> void:
	var panel := _make_panel()
	var mesh_section: Control = panel.get_node("VBox/MeshSection")
	assert_bool(mesh_section.visible).is_false()
	assert_bool((panel.get_node("VBox/Gamma") as Control).visible).is_true()

	panel.set_specimen_type("mesh")
	assert_bool(mesh_section.visible).is_true()
	for n in ["GammaLabel", "Gamma", "OpacityLabel", "Opacity", "QualityLabel", "Quality",
			"AdvancedToggle", "AdvancedScroll"]:
		assert_bool((panel.get_node("VBox/" + n) as Control).visible).is_false()

	panel.set_specimen_type("volume")
	assert_bool(mesh_section.visible).is_false()
	assert_bool((panel.get_node("VBox/Gamma") as Control).visible).is_true()


# Edit mode merges get_display() into the specimen's manifest entry; a mesh must not come back
# carrying every volume quality key.
func test_mesh_mode_display_has_only_mesh_keys() -> void:
	var panel := _make_panel()
	panel.set_specimen_type("mesh")
	var keys := panel.get_display().keys()
	keys.sort()
	assert_array(keys).is_equal(["color", "inner_surfaces", "metallic", "opacity", "rim",
		"roughness", "shader"])


func test_mesh_section_changes_emit_display_changed() -> void:
	var panel := _make_panel()
	panel.set_specimen_type("mesh")
	var seen: Array[Dictionary] = []
	panel.display_changed.connect(func(d: Dictionary): seen.append(d))
	(panel.get_node("VBox/MeshSection/Surface/Metallic") as HSlider).value = 0.7
	assert_int(seen.size()).is_equal(1)
	assert_float(seen[0]["metallic"]).is_equal_approx(0.7, 0.001)


func test_set_display_reaches_the_mesh_section() -> void:
	var panel := _make_panel()
	panel.set_specimen_type("mesh")
	panel.set_display({"color": "#8e44ad", "rim": 0.0})
	var d := panel.get_display()
	assert_str(d["color"]).is_equal("#8e44ad")
	assert_float(d["rim"]).is_equal_approx(0.0, 0.001)


func test_vr_panel_uses_swatches() -> void:
	var panel := _make_panel()
	panel.set_exit_vr_visible(true)
	assert_bool((panel.get_node("VBox/MeshSection/Surface/Swatches") as Control).visible).is_true()
```

Also append this test to `viewer/tests/test_main_scene.gd`:

```gdscript
func test_mesh_panel_stays_clear_of_the_story_panel() -> void:
	var main := await _make_main()
	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")
	var story: Control = main.get_node("CanvasLayer/StoryPanel")
	panel.set_specimen_type("mesh")
	await get_tree().process_frame
	assert_float(panel.get_global_rect().end.x).is_less_equal(story.get_global_rect().position.x)
	# Tall enough for every mesh control: the VBox's minimum height fits inside the panel.
	var vbox: Control = panel.get_node("VBox")
	assert_float(panel.size.y).is_greater_equal(vbox.get_combined_minimum_size().y + 20.0)
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run with `-a res://tests/test_display_settings_panel.gd`. Expected: FAIL, because `VBox/MeshSection` is not found and `set_specimen_type` doesn't exist.

- [ ] **Step 3: Implement.** In `display_settings_panel.gd`, add the following below `var _advanced_open := false`:

```gdscript
## "volume" or "mesh": which controls the panel shows, and what get_display() reports.
var _specimen_type := "volume"
var _mesh_section: MeshSettingsSection

## The always-visible volume controls, hidden while a mesh is staged.
const VOLUME_NODES := ["GammaLabel", "Gamma", "OpacityLabel", "Opacity", "QualityLabel",
	"Quality", "AdvancedToggle"]
```

At the very top of `_ready()`, before `_gamma_slider.min_value = 0.1`, add:

```gdscript
	_mesh_section = MeshSettingsSection.new()
	_mesh_section.visible = false
	$VBox.add_child(_mesh_section)
	$VBox.move_child(_mesh_section, _advanced_scroll.get_index() + 1)
	_mesh_section.changed.connect(_emit_changed)
```

Add a new public function after `_on_advanced_toggled`:

```gdscript
## Shows the mesh controls or the volume controls, to match the staged specimen.
func set_specimen_type(type: String) -> void:
	_specimen_type = "mesh" if type == "mesh" else "volume"
	var is_mesh := _specimen_type == "mesh"
	for n in VOLUME_NODES:
		($VBox.get_node(n) as Control).visible = not is_mesh
	_advanced_scroll.visible = _advanced_open and not is_mesh
	_mesh_section.visible = is_mesh
	_resize_desktop()
```

Replace the size lines in `_resize_desktop()`:

```gdscript
	var width := 280.0 if _advanced_open else 240.0
	var height := 560.0 if _advanced_open else 260.0
```

with:

```gdscript
	var width := 240.0
	var height := 260.0
	if _specimen_type == "mesh":
		height = $VBox.get_combined_minimum_size().y + 20.0
	elif _advanced_open:
		width = 280.0
		height = 560.0
```

As the first line of `get_display()`, add:

```gdscript
	if _specimen_type == "mesh":
		return _mesh_section.get_display()
```

As the first line of `set_display()`, add:

```gdscript
	# Keep the mesh section in step whichever type is staged: both panels sync through here.
	_mesh_section.set_display(display)
```

In `set_exit_vr_visible`, add `_mesh_section.set_vr(shown)` after `is_vr = shown`.

- [ ] **Step 4: Run the whole viewer suite.** Expected: all tests pass, including the two Task 1 geometry tests.

- [ ] **Step 5: Commit.** Use the message `feat(panel): mesh settings section replaces volume controls for meshes`.

---

### Task 7: `main.gd` tells the panels what is staged

**Files:**
- Modify: `viewer/scripts/main.gd` (after each `$SpecimenStage.stage(...)` call, at about :239 and :464)
- Test: `viewer/tests/test_main_scene.gd` (append)

**Interfaces:**
- Consumes: `DisplaySettingsPanel.set_specimen_type` (Task 6).
- Produces: `main._set_panels_specimen_type(data: RefCounted) -> void`.

- [ ] **Step 1: Write the failing test.** Append to `test_main_scene.gd`:

```gdscript
func test_panels_follow_the_staged_specimen_type() -> void:
	var main := await _make_main()
	var desktop: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")
	var vr: DisplaySettingsPanel = main.get_node("XROrigin3D/PanelViewport/DisplaySettingsPanel")
	# The fixture bundle is a volume.
	assert_bool((desktop.get_node("VBox/MeshSection") as Control).visible).is_false()

	# `main` is typed Node3D here, so call through call() rather than a static method lookup.
	main.call("_set_panels_specimen_type", WebMeshData.new())
	assert_bool((desktop.get_node("VBox/MeshSection") as Control).visible).is_true()
	assert_bool((vr.get_node("VBox/MeshSection") as Control).visible).is_true()
```

- [ ] **Step 2: Run it and confirm it fails.** Expected: FAIL, because `_set_panels_specimen_type` doesn't exist.

- [ ] **Step 3: Implement.** Add to `main.gd`, next to `_display_for_specimen`:

```gdscript
## Shows the mesh or volume controls on both panels, to match what was just staged.
func _set_panels_specimen_type(data: RefCounted) -> void:
	var type := "mesh" if data is WebMeshData else "volume"
	$CanvasLayer/DisplaySettingsPanel.set_specimen_type(type)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_specimen_type(type)
```

Call `_set_panels_specimen_type(data)` on the line immediately after both `$SpecimenStage.stage(...)` calls: the one in `_wire_story_panels`'s `on_page_pinned`, and the one in the manifest-loaded path at about :464.

- [ ] **Step 4: Run the full viewer suite.** Expected: everything passes.

- [ ] **Step 5: Commit.** Use the message `feat(viewer): panels switch to mesh controls when a mesh is staged`.

---

### Task 8: Render check, deploy variants, docs (orchestrator)

**Files:**
- Modify: `.github/workflows/pages.yml` (the mesh bake step), `README.md` (Meshes section, the manifest table, the synthetic mesh bundles section), `.claude/skills/bundling-meshes/SKILL.md`, `demo/knot/story.md` (the Shaders page)

- [ ] **Step 1: Render check.** Bake the knot three ways: default; `--opacity 0.4`; and `--opacity 0.4` with `inner_surfaces: true` patched into the manifest. Serve them, then render each with `viewer/tools/shader_probe.gd` at `--view=0.6,0.5,2.2`. **Look at the three PNGs.** Default must be opaque gold and lit, with a visible rim. 0.4 must be a single translucent shell. Inner must show the crossings through the near tube. Also confirm the desktop panel shows the mesh section (the probe screenshots include the panel).

- [ ] **Step 2: Deploy variants.** In `pages.yml`, replace the shader loop with:

```yaml
          for shader in surface pearl crystal hologram; do
            ascribe-bundle build knot.stl --shader "$shader" --story demo/knot/story.md \
              --title "Torus knot ($shader)" -o "build/web/knot_$shader"
          done
          # Translucent with inner surfaces, to show the crossings through the near tube.
          ascribe-bundle build knot.stl --opacity 0.4 --story demo/knot/story.md \
            --title "Torus knot (inner surfaces)" -o build/web/knot_inner
          python -c "import json; p='build/web/knot_inner/manifest.json'; m=json.load(open(p)); m['specimens'][0]['display']['inner_surfaces']=True; json.dump(m, open(p, 'w'), indent=2)"
```

Also change the main `knot` bake to drop `--shader pearl`, so it uses the default.

- [ ] **Step 3: Docs.**
  - README: replace the shader table with the four shaders. Document `--color` (with the PowerShell quoting note) and `--opacity`, the mesh panel controls, and the two translucency modes. Add `color`, `roughness`, `metallic`, `rim` and `inner_surfaces` rows to the manifest table. Update the synthetic mesh bundles list (`knot_surface`, `knot_inner`, ...).
  - Skill: the same, kept under 500 words. "Always pass `--shader`" becomes "the default `surface` works; tune it in edit mode".
  - knot story: the Shaders page describes the surface controls and `knot_inner`.

- [ ] **Step 4: Verify everything.** Run the bundler suite and the viewer suite. Then dry-run the new pages step locally, as was done for `8b0652a`.

- [ ] **Step 5: Commit.** Use the message `docs: tunable mesh surface material`.

---

## Execution notes

- novu (agy over hcom) implements Tasks 2–6, one task per message, each with its acceptance command. I take Task 1 (to land the fix first and check the Godot test harness works), Task 7 (small) and Task 8 (needs eyes on renders), and I review every task's diff before sending the next.
