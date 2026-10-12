## Builds and updates the tunable `surface` material for mesh specimens from a bundle's
## `display` dict. It is a StandardMaterial3D rather than a hand-written shader: the stock
## material is already compiled for the Compatibility (WebGL2) renderer and exercised in XR
## stereo, and every look parameter is a plain property, so slider drags cost nothing.
class_name MeshSurfaceMaterial
extends RefCounted

## Mesh shader names a bundle may use. `surface` is this material; the rest are fixed-look
## shaders under res://shaders/.
const SHADERS := ["surface", "pearl", "crystal", "holographic"]
const DEFAULT_COLOR := "#d4af37"
const DEPTH_ONLY := preload("res://shaders/depth_only.gdshader")

## One material per render configuration, never drawn, held only so their shader variants stay
## alive: Godot frees a StandardMaterial3D variant once nothing uses it, and recompiling one on
## the web is a visible stall. With these pinned, toggling inner surfaces reuses the variant.
static var _variant_pins: Array[Material] = []


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
	_pin_variants()
	var mat := _new_surface()
	apply(mat, display)
	return mat


## Updates `mat` in place from `display`. Sliders only ever change uniforms here: the render
## configuration (transparency, culling, depth, extra pass) depends on inner surfaces alone,
## because on the web every configuration change recompiles the shader -- which is the stall
## opacity used to cause when it crossed 1.
static func apply(mat: StandardMaterial3D, display: Dictionary) -> void:
	var s := resolved(display)
	_set_look(mat, s)
	# Inner surfaces only means something while there is something to see through; at full
	# opacity, blending without depth writes would draw far surfaces over near ones.
	var inner: bool = s["inner_surfaces"] and s["opacity"] < 1.0
	if inner:
		# Every layer, additively. Triangles are drawn in index order, not depth order, and
		# "over" blending depends on order -- overlapping layers showed as speckled triangles.
		# Addition is commutative, so the result is the same whatever the draw order: an x-ray
		# look, brighter where layers stack.
		_set_config(mat, BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.CULL_DISABLED,
			BaseMaterial3D.DEPTH_DRAW_DISABLED, BaseMaterial3D.BLEND_MODE_ADD)
		mat.next_pass = null
	else:
		# Nearest surface: one blended shell. Both faces, so open meshes (CAD shells, cut
		# isosurfaces) show their inside instead of holes; Godot flips back-face normals so they
		# light correctly. The Compatibility renderer ignores ALPHA_DEPTH_PRE_PASS, so a
		# depth-only pass sorted ahead of this one makes only the nearest surface pass the depth
		# test. Used at full opacity too, so opacity never changes the configuration.
		_set_config(mat, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS,
			BaseMaterial3D.CULL_DISABLED, BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY,
			BaseMaterial3D.BLEND_MODE_MIX)
		if not (mat.next_pass is ShaderMaterial):
			mat.next_pass = depth_pass_for(mat)


## A depth-only pass to put ahead of `mat`, so only its nearest surface passes the depth test.
static func depth_pass_for(mat: Material) -> ShaderMaterial:
	var depth_pass := ShaderMaterial.new()
	depth_pass.shader = DEPTH_ONLY
	depth_pass.render_priority = mat.render_priority - 1
	return depth_pass


static func _new_surface() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# Always on: rim 0 reads as off, and toggling the flag itself would recompile the shader.
	mat.rim_enabled = true
	mat.rim_tint = 0.5
	return mat


## The uniforms: colour, alpha, roughness, metallic, rim.
static func _set_look(mat: StandardMaterial3D, s: Dictionary) -> void:
	var color := Color.from_string(s["color"], Color.from_string(DEFAULT_COLOR, Color.WHITE))
	color.a = s["opacity"]
	mat.albedo_color = color
	mat.roughness = s["roughness"]
	mat.metallic = s["metallic"]
	mat.rim = s["rim"]


## Assigns only what differs: each of these is part of the shader variant.
static func _set_config(mat: StandardMaterial3D, transparency: BaseMaterial3D.Transparency,
		cull: BaseMaterial3D.CullMode, depth: BaseMaterial3D.DepthDrawMode,
		blend: BaseMaterial3D.BlendMode) -> void:
	if mat.transparency != transparency:
		mat.transparency = transparency
	if mat.cull_mode != cull:
		mat.cull_mode = cull
	if mat.depth_draw_mode != depth:
		mat.depth_draw_mode = depth
	if mat.blend_mode != blend:
		mat.blend_mode = blend


static func _pin_variants() -> void:
	if not _variant_pins.is_empty():
		return
	for inner in [false, true]:
		var pin := _new_surface()
		apply(pin, {"opacity": 0.5, "inner_surfaces": inner})
		_variant_pins.append(pin)
