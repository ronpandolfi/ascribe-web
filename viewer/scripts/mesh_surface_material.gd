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
	# Only `#rrggbb`, as the manifest schema says. Color.from_string alone would also accept
	# Godot's named colours ("gold"), which a bundle saved back through edit mode then fails to
	# validate.
	var color := str(display.get("color", DEFAULT_COLOR)).to_lower()
	if color.length() != 7 or not color.begins_with("#") or not color.substr(1).is_valid_hex_number():
		color = DEFAULT_COLOR
	return {
		"color": color,
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
