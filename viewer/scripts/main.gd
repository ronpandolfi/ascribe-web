## Main scene: loads a content bundle (from `?bundle=` on web, or a fixture bundle otherwise),
## stages its first specimen, and offers WebXR entry.
extends Node3D

var xr_interface: WebXRInterface
var _loader: BundleLoader
var _manifest: Dictionary = {}
var _specimens: Dictionary = {}
var _bundle_base_url: String = ""
var _current_display: Dictionary = {}

## Set true the moment the user manually adjusts the display settings panel; once set, automatic
## quality-tier application (startup, XR enter/exit) stops overriding their choice.
var _user_touched_quality: bool = false

## Camera pose as of the last save, so moving the view can mark the save stale the same way
## moving a slider does.
var _saved_pose: String = ""

## Quality the loaded bundle asked for, if any. An author who set and saved a quality meant it,
## so it wins over the automatic tier -- but never upward in XR, where exceeding the tier means
## dropping frames in a headset rather than merely rendering slowly.
var _authored_quality: Dictionary = {}

## Tracks fullscreen state for headless mode and environments where window mode queries
## are non-blocking or virtualized.
var _is_fullscreen_state: bool = false
var _was_fullscreen: bool = false

const DEFAULT_BUNDLE := "res://tests/fixtures/tiny_bundle"

## 3D resolution scale in XR. Must remain 1.0 because Godot's WebGL Compatibility (GLES3)
## renderer does not support multiview blit when scaling_3d_scale < 1.0 (it only upscales to the
## right eye, breaking stereoscopic rendering). Instead, XR performance scaling is handled via
## distance-adaptive raymarch step budgeting and empty-space skipping.
const XR_SCALING_3D_SCALE := 1.0

var _current_xr_adaptive_steps: int = -1
var _last_xr_cam_pos: Vector3 = Vector3.ZERO
var _last_xr_cam_rot: Basis = Basis.IDENTITY
var _last_stage_pos: Vector3 = Vector3.ZERO
var _last_stage_rot: Basis = Basis.IDENTITY
var _smoothed_angular_speed: float = 0.0


func _ready() -> void:
	xr_interface = XRServer.find_interface("WebXR")
	if xr_interface:
		xr_interface.session_supported.connect(_on_session_supported)
		xr_interface.session_started.connect(_on_session_started)
		xr_interface.session_ended.connect(_on_session_ended)
		xr_interface.session_failed.connect(func(msg): push_error("WebXR failed: " + msg))
		xr_interface.is_session_supported("immersive-vr")
	$CanvasLayer/EnterVR.pressed.connect(_enter_vr)
	$CanvasLayer/EnterVR.visible = false

	$CanvasLayer/Fullscreen.pressed.connect(_toggle_fullscreen)
	$CanvasLayer/StoryPanel.visibility_changed.connect(_update_fullscreen_button_layout)
	get_tree().root.size_changed.connect(_on_window_size_changed)
	_update_fullscreen_button_layout()
	_update_fullscreen_button()
	var stage_node: Node3D = $SpecimenStage
	_last_stage_pos = stage_node.global_position
	_last_stage_rot = stage_node.global_basis.orthonormalized()
	_init_webxr_ffr_hooks()

	_loader = BundleLoader.new()
	add_child(_loader)
	_loader.progress.connect(_on_progress)
	_loader.loaded.connect(_on_loaded)
	_loader.failed.connect(_on_failed)

	$CanvasLayer/ProgressBar.value = 0.0
	if $CanvasLayer.has_node("LoadingLabel"):
		$CanvasLayer/LoadingLabel.text = "Loading manifest..."
	_bundle_base_url = _resolve_bundle_url()
	_loader.load_bundle(_bundle_base_url)

	$XROrigin3D/PanelViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_wire_panel_textures()
	$CanvasLayer/AxesGadget.camera = $Camera3D
	_frame_specimen_for_desktop()
	_wire_xr_grab()
	_wire_display_panels()
	_wire_story_panels()
	_apply_quality_tier()


## Aims the desktop orbit camera at the staged specimen.
##
## The specimen sits ahead of the XR origin at roughly eye height (see SpecimenStage's transform
## in main.tscn) rather than at the world origin, because in a headset the origin is on the floor
## between the user's feet -- a specimen there spawns underneath them. The desktop camera has to
## orbit that same point instead of the origin.
func _frame_specimen_for_desktop() -> void:
	var cam: OrbitCamera = $Camera3D
	cam.target = $SpecimenStage.position
	cam.frame(1.0)
	# An explicit `?view=yaw,pitch,distance` (or `--view=` on desktop) overrides the default
	# framing, so a specific view can be shared, reported in a bug, or replayed by the
	# shader probe.
	var view := _resolve_view_value()
	if view != "" and not cam.apply_pose_string(view):
		push_warning("ignoring malformed view '%s'" % [view])


## Reads a requested camera pose from `--view=` (desktop) or `?view=` (web); "" when absent.
func _resolve_view_value() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			return arg.substr("--view=".length())
	if OS.has_feature("web"):
		var search: String = JavaScriptBridge.eval("window.location.search", true)
		if search is String and search != "":
			for pair in (search as String).trim_prefix("?").split("&"):
				var kv := pair.split("=", true, 1)
				if kv.size() == 2 and kv[0] == "view":
					return kv[1].uri_decode()
	return ""


## Key shortcuts:
## - V: prints current view as a shareable URL to the console
## - F / F11: toggles fullscreen mode
## - Escape: exits fullscreen mode
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode
	if key == KEY_V:
		var pose: String = ($Camera3D as OrbitCamera).pose_string()
		if OS.has_feature("web"):
			var href = JavaScriptBridge.eval("location.origin + location.pathname", true)
			var bundle := _bundle_base_url.get_file()
			print("view URL: %s?bundle=%s&view=%s" % [href, bundle, pose])
		else:
			print("view: %s" % [pose])
	elif key == KEY_F or key == KEY_F11:
		_toggle_fullscreen()
	elif key == KEY_ESCAPE and _is_fullscreen():
		_exit_fullscreen()


## Points each in-VR panel quad at its SubViewport's live texture.
##
## The scene stores these as ViewportTexture sub-resources with a `viewport_path`, which does not
## reliably resolve at runtime -- when it fails the quad falls back to the missing-texture
## material and the panel shows up in the headset as a pink checkerboard. Assigning
## `SubViewport.get_texture()` directly sidesteps the path lookup entirely.
func _wire_panel_textures() -> void:
	var pairs := [
		[$XROrigin3D/PanelQuad, $XROrigin3D/PanelViewport],
		[$XROrigin3D/StoryQuad, $XROrigin3D/StoryViewport],
	]
	for pair in pairs:
		var quad: MeshInstance3D = pair[0]
		var viewport: SubViewport = pair[1]
		var mat := quad.get_surface_override_material(0)
		if mat is StandardMaterial3D:
			# Duplicate so the two quads can't share one material instance.
			var own: StandardMaterial3D = (mat as StandardMaterial3D).duplicate()
			own.albedo_texture = viewport.get_texture()
			own.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			quad.set_surface_override_material(0, own)


## Wires the grab controller node to the two hand controllers and the staged specimen. Left as a
## separate step (rather than tscn export properties) so it stays simple to keep in sync with the
## scene tree above.
func _wire_xr_grab() -> void:
	var grab: XRGrab = $XRGrab
	grab.left_controller = $XROrigin3D/LeftController
	grab.right_controller = $XROrigin3D/RightController
	grab.specimen_stage = $SpecimenStage

	var pointer := $XROrigin3D/XRPanelPointer
	pointer.right_controller = $XROrigin3D/RightController
	pointer.left_controller = $XROrigin3D/LeftController
	pointer.panel_quad = $XROrigin3D/PanelQuad
	pointer.panel_viewport = $XROrigin3D/PanelViewport
	pointer.laser_dot = $XROrigin3D/LaserDot

	# Story panel is removed from XR mode per user request
	var story_pointer := $XROrigin3D/StoryPanelPointer
	story_pointer.right_controller = $XROrigin3D/RightController
	story_pointer.left_controller = $XROrigin3D/LeftController
	story_pointer.panel_quad = $XROrigin3D/StoryQuad
	story_pointer.panel_viewport = $XROrigin3D/StoryViewport
	story_pointer.laser_dot = $XROrigin3D/StoryLaserDot
	story_pointer.set_physics_process(false)
	$XROrigin3D/StoryQuad.visible = false
	$XROrigin3D/StoryLaserDot.visible = false
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Connects both the desktop and in-VR display settings panels to the staged specimen. They are
## separate instances of the same `display_settings_panel.tscn` scene (one drawn to the desktop
## CanvasLayer, one rendered into the SubViewport behind the in-VR quad) so each can be adjusted
## independently without either mode fighting the other.
func _wire_display_panels() -> void:
	var desktop_panel: DisplaySettingsPanel = $CanvasLayer/DisplaySettingsPanel
	var vr_panel: DisplaySettingsPanel = $XROrigin3D/PanelViewport/DisplaySettingsPanel

	var on_display_changed := func(source: DisplaySettingsPanel, other: DisplaySettingsPanel, display: Dictionary) -> void:
		_user_touched_quality = true
		_current_display.merge(display, true)
		other.set_display(display)
		_current_xr_adaptive_steps = -1
		$SpecimenStage.apply_display(_current_display)
		if get_viewport().use_xr and (display.has("ffr_enabled") or display.has("ffr_level")):
			_apply_webxr_fixed_foveation(bool(_current_display.get("ffr_enabled", true)), float(_current_display.get("ffr_level", 1.0)))

	desktop_panel.display_changed.connect(func(d: Dictionary): on_display_changed.call(desktop_panel, vr_panel, d))
	vr_panel.display_changed.connect(func(d: Dictionary): on_display_changed.call(vr_panel, desktop_panel, d))

	# Only the in-VR panel offers a way out: in a headset there is no browser chrome to fall
	# back on, and the system gesture is not obvious to someone wearing it for the first time.
	vr_panel.set_exit_vr_visible(true)
	vr_panel.exit_vr_requested.connect(_exit_vr)

	# Edit mode is a local authoring affordance: it needs `ascribe-bundle serve --edit` behind
	# it, so it is opt-in via ?edit=1 and never offered for a bundle loaded from elsewhere.
	desktop_panel.set_edit_enabled(_edit_enabled())
	desktop_panel.save_requested.connect(_save_bundle_settings)


## Connects both the desktop and in-VR story panels: on page navigation that pins a different
## specimen than the one currently staged, stage it.
func _wire_story_panels() -> void:
	var on_page_pinned := func(specimen_id: String) -> void:
		if specimen_id == $SpecimenStage.current_id:
			return
		var data = _specimens.get(specimen_id, null)
		if data == null:
			return
		var spec_display := _display_for_specimen(specimen_id)
		$SpecimenStage.stage(specimen_id, data, spec_display)
		_last_stage_pos = $SpecimenStage.global_position
		_last_stage_rot = $SpecimenStage.global_basis.orthonormalized()
		_current_display.merge(spec_display, true)
		$CanvasLayer/DisplaySettingsPanel.set_display(spec_display)
		$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_display(spec_display)
		$SpecimenStage.apply_display(_current_display)
	$CanvasLayer/StoryPanel.page_pinned.connect(on_page_pinned)
	$XROrigin3D/StoryViewport/StoryPanel.page_pinned.connect(on_page_pinned)


## Looks up a specimen's `display` dict from the manifest, or `{}` if not found.
func _display_for_specimen(specimen_id: String) -> Dictionary:
	for spec in _manifest.get("specimens", []):
		if spec.get("id", "") == specimen_id:
			return spec.get("display", {})
	return {}


## Applies the current quality tier (desktop/mobile/XR) to the staged specimen, unless the user
## has already manually adjusted quality via a settings panel.
func _apply_quality_tier() -> void:
	if _user_touched_quality:
		return
	var features := PackedStringArray()
	if OS.has_feature("web_android"):
		features.append("web_android")
	if OS.has_feature("web_ios"):
		features.append("web_ios")
	if OS.has_feature("web"):
		var is_quest_or_mobile: bool = bool(JavaScriptBridge.eval(
			"/Quest|OculusBrowser|Pico|Vive|Android|Mobile|iPhone|iPad/i.test(navigator.userAgent)"
		))
		if is_quest_or_mobile:
			features.append("mobile")
	var xr_active := get_viewport().use_xr
	var tier := Quality.pick_tier(features, xr_active)
	var is_constrained := xr_active or features.has("mobile") or features.has("web_android") or features.has("web_ios")
	if not _authored_quality.is_empty():
		# Honour the bundle's own setting, capped by what this device can afford.
		var steps: int = int(_authored_quality["max_steps"])
		if is_constrained:
			steps = mini(steps, int(tier["max_steps"]))
		tier["max_steps"] = steps
		if _authored_quality.has("step_size"):
			tier["step_size"] = float(_authored_quality["step_size"])
		else:
			tier["step_size"] = Quality.step_size_for(steps)
		tier["lut_substeps"] = 1 if is_constrained else Quality.lut_substeps_for(steps)
	_current_display.merge(tier, true)
	$SpecimenStage.apply_display(_current_display)
	$CanvasLayer/DisplaySettingsPanel.set_display(_current_display)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_display(_current_display)


## Feeds the staged volume the current per-eye offsets while an XR session is running, so the
## raymarch starts from the correct origin for each eye. The offsets are re-read every frame
## rather than cached: IPD can change between sessions, and some runtimes only report a
## meaningful value once tracking has settled.
func _process(delta: float) -> void:
	_refresh_save_status()
	_update_adaptive_resolution(delta)
	if not OS.has_feature("web"):
		var fs := _is_fullscreen()
		if fs != _was_fullscreen:
			_was_fullscreen = fs
			_update_fullscreen_button()

	if xr_interface == null or not get_viewport().use_xr:
		return
	var origin: XROrigin3D = $XROrigin3D
	var head: Transform3D = $XROrigin3D/XRCamera3D.global_transform
	var left := xr_interface.get_transform_for_view(0, origin.global_transform)
	var right := xr_interface.get_transform_for_view(1, origin.global_transform)
	$SpecimenStage.set_eye_offsets(
		SpecimenStage.eye_offset_in_view_space(head, left),
		SpecimenStage.eye_offset_in_view_space(head, right))


## True when the viewer was asked for edit mode (`?edit=1` on web, `--edit` on desktop).
##
## The save itself goes to the local server, which only accepts it when started with
## `ascribe-bundle serve --edit`; this flag just decides whether to offer the button.
func _edit_enabled() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg == "--edit":
			return true
	if OS.has_feature("web"):
		var search: String = JavaScriptBridge.eval("window.location.search", true)
		if search is String and search != "":
			for pair in (search as String).trim_prefix("?").split("&"):
				if pair == "edit=1":
					return true
	return false


## Writes the current view and display settings back into the bundle's manifest.
##
## The browser cannot write files, so this POSTs the updated manifest to the local server, which
## validates it and replaces the file. Anything the panel does not control -- the gradient, the
## story, specimen ids -- is carried through untouched rather than regenerated, so saving a view
## never quietly discards a hand-tuned transfer function.
func _save_bundle_settings() -> void:
	if _manifest.is_empty():
		return
	var panel: DisplaySettingsPanel = $CanvasLayer/DisplaySettingsPanel
	var updated := _manifest.duplicate(true)
	updated["view"] = ($Camera3D as OrbitCamera).pose_string()

	var display: Dictionary = panel.get_display()
	for specimen in updated.get("specimens", []):
		if specimen.get("id", "") == $SpecimenStage.current_id:
			var existing: Dictionary = specimen.get("display", {})
			for key in display:
				existing[key] = display[key]
			specimen["display"] = existing

	var url := _bundle_base_url.rstrip("/") + "/manifest.json"
	var request := _loader.make_request()
	add_child(request)
	var body := JSON.stringify(updated, "  ")
	var err := request.request(url, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		panel.set_save_status("Save failed (request error %d)" % [err])
		request.queue_free()
		return

	var result: Array = await request.request_completed
	request.queue_free()
	var code: int = result[1]
	if code == 200:
		_manifest = updated
		_saved_pose = str(updated.get("view", ""))
		panel.set_save_status("Saved")
	elif code == 403:
		panel.set_save_status("Saving disabled -- serve with --edit")
	else:
		panel.set_save_status("Save failed (HTTP %d)" % [code])


## Clears a "Saved" label once the camera has moved away from what was saved. Slider changes
## clear it themselves; the camera is not the panel's to watch.
func _refresh_save_status() -> void:
	if _saved_pose == "":
		return
	if ($Camera3D as OrbitCamera).pose_string() != _saved_pose:
		_saved_pose = ""
		$CanvasLayer/DisplaySettingsPanel.clear_save_status()


## Resolves the bundle base URL: `--bundle=<path-or-url>` after `--` on desktop, else the
## `?bundle=` query param on web, falling back to the fixture bundle when neither is given.
func _resolve_bundle_url() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bundle="):
			var value := arg.substr("--bundle=".length())
			if value != "":
				return value
	if OS.has_feature("web"):
		var search: String = JavaScriptBridge.eval("window.location.search", true)
		if search is String and search != "":
			var params := (search as String).trim_prefix("?").split("&")
			for pair in params:
				var kv := pair.split("=", true, 1)
				if kv.size() == 2 and kv[0] == "bundle" and kv[1] != "":
					return _resolve_web_bundle_value(kv[1])
	return DEFAULT_BUNDLE


## Resolves a raw `?bundle=` value on web. `res://` and absolute http(s) URLs pass through
## unchanged; anything else is percent-decoded and resolved against the page's own location (via
## `new URL(raw, location.href)`) so HTTPRequest.request() always gets an absolute URL -- it can't
## handle relative ones itself.
func _resolve_web_bundle_value(raw: String) -> String:
	if raw.begins_with("res://") or raw.begins_with("http://") or raw.begins_with("https://"):
		return raw
	var decoded: String = raw.uri_decode()
	var js := "new URL(%s, location.href).href" % [JSON.stringify(decoded)]
	var resolved = JavaScriptBridge.eval(js, true)
	if resolved is String and resolved != "":
		return resolved
	return decoded


func _on_progress(stage: String, ratio: float) -> void:
	$CanvasLayer/ProgressBar.value = ratio * 100.0
	if $CanvasLayer.has_node("LoadingLabel") and stage != "":
		$CanvasLayer/LoadingLabel.text = stage


func _on_loaded(manifest: Dictionary, specimens: Dictionary) -> void:
	_manifest = manifest
	_specimens = specimens
	$CanvasLayer/ProgressBar.visible = false
	if $CanvasLayer.has_node("LoadingLabel"):
		$CanvasLayer/LoadingLabel.visible = false

	# A bundle can carry its own default framing (saved by edit mode). An explicit --view=/?view=
	# still wins, so a shared link always shows what it promised.
	var requested_view := _resolve_view_value()
	var saved_view: String = str(manifest.get("view", ""))
	if requested_view == "" and saved_view != "":
		if not ($Camera3D as OrbitCamera).apply_pose_string(saved_view):
			push_warning("bundle has a malformed view '%s'" % [saved_view])

	var spec_list: Array = manifest.get("specimens", [])
	if spec_list.is_empty():
		$ErrorScreen.show_error("Bundle '%s' has no specimens" % [manifest.get("title", "")])
		return

	var first_spec: Dictionary = spec_list.front()
	var spec_id: String = first_spec.get("id", "")
	var data = specimens.get(spec_id, null)
	if data == null:
		$ErrorScreen.show_error("Specimen '%s' failed to decode" % [spec_id])
		return

	var spec_display: Dictionary = first_spec.get("display", {})
	if spec_display.has("max_steps"):
		_authored_quality = {
			"max_steps": int(spec_display["max_steps"]),
			"step_size": float(spec_display.get(
				"step_size", Quality.step_size_for(int(spec_display["max_steps"])))),
		}
	$SpecimenStage.stage(spec_id, data, spec_display)
	var stage_node: Node3D = $SpecimenStage
	_last_stage_pos = stage_node.global_position
	_last_stage_rot = stage_node.global_basis.orthonormalized()
	# Show the bundle's own gamma/opacity on the panels. Without this the sliders sit at their
	# defaults while the render uses the manifest's values -- the panel lies about the current
	# state, and in edit mode saving would write the slider defaults over a tuned manifest.
	$CanvasLayer/DisplaySettingsPanel.set_display(spec_display)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_display(spec_display)
	_apply_quality_tier()

	var story: Array = manifest.get("story", [])
	$CanvasLayer/StoryPanel.set_story(story, _bundle_base_url)
	# XR mode does not show story text
	$XROrigin3D/StoryQuad.visible = false
	$XROrigin3D/StoryLaserDot.visible = false
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_update_fullscreen_button_layout()


func _on_failed(message: String) -> void:
	$CanvasLayer/ProgressBar.visible = false
	if $CanvasLayer.has_node("LoadingLabel"):
		$CanvasLayer/LoadingLabel.visible = false
	$ErrorScreen.show_error(message)


func _on_session_supported(mode: String, supported: bool) -> void:
	if mode == "immersive-vr":
		$CanvasLayer/EnterVR.visible = supported


func _enter_vr() -> void:
	xr_interface.session_mode = "immersive-vr"
	xr_interface.requested_reference_space_types = "local-floor, local"
	xr_interface.required_features = "local-floor"
	if not xr_interface.initialize():
		push_error("WebXR initialize() failed")


## Ends the WebXR session. `uninitialize()` drops the session, which fires session_ended and
## puts the viewport back into desktop mode.
func _exit_vr() -> void:
	if xr_interface != null:
		xr_interface.uninitialize()
	get_viewport().use_xr = false
	get_viewport().scaling_3d_scale = 1.0
	$Camera3D.current = true
	$XROrigin3D/XRCamera3D.current = false
	$XROrigin3D/PanelViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$CanvasLayer.visible = true
	$CanvasLayer/EnterVR.visible = true
	$CanvasLayer/Fullscreen.visible = true


func _on_session_started() -> void:
	get_viewport().use_xr = true
	get_viewport().scaling_3d_scale = XR_SCALING_3D_SCALE
	$XROrigin3D/XRCamera3D.current = true
	$Camera3D.current = false
	$XROrigin3D/PanelViewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$XROrigin3D/StoryQuad.visible = false
	$XROrigin3D/StoryLaserDot.visible = false
	$CanvasLayer.visible = false
	$CanvasLayer/EnterVR.visible = false
	$CanvasLayer/Fullscreen.visible = false
	_last_xr_cam_rot = $XROrigin3D/XRCamera3D.global_basis
	_last_xr_cam_pos = $XROrigin3D/XRCamera3D.global_position
	_last_stage_rot = $SpecimenStage.global_basis.orthonormalized()
	_last_stage_pos = $SpecimenStage.global_position
	_smoothed_angular_speed = 0.0
	_current_xr_adaptive_steps = -1
	_apply_quality_tier()
	var active_display: Dictionary = $CanvasLayer/DisplaySettingsPanel.get_display()
	_apply_webxr_fixed_foveation(bool(active_display.get("ffr_enabled", true)), float(active_display.get("ffr_level", 1.0)))


func _on_session_ended() -> void:
	get_viewport().use_xr = false
	get_viewport().scaling_3d_scale = 1.0
	$Camera3D.current = true
	$XROrigin3D/XRCamera3D.current = false
	$XROrigin3D/PanelViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$XROrigin3D/StoryViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	$CanvasLayer.visible = true
	$CanvasLayer/Fullscreen.visible = true
	_current_xr_adaptive_steps = -1
	_smoothed_angular_speed = 0.0
	_last_stage_rot = $SpecimenStage.global_basis.orthonormalized()
	_last_stage_pos = $SpecimenStage.global_position
	_apply_quality_tier()


## True when the application is currently running fullscreen.
func _is_fullscreen() -> bool:
	if OS.has_feature("web"):
		var js_fs = JavaScriptBridge.eval("Boolean(document.fullscreenElement)", true)
		if js_fs != null:
			return bool(js_fs)
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return true
	return _is_fullscreen_state


## Toggles window mode between windowed and fullscreen.
func _toggle_fullscreen() -> void:
	if _is_fullscreen():
		_exit_fullscreen()
	else:
		_enter_fullscreen()


func _enter_fullscreen() -> void:
	_is_fullscreen_state = true
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_update_fullscreen_button()


func _exit_fullscreen() -> void:
	_is_fullscreen_state = false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if (document.exitFullscreen && document.fullscreenElement) { document.exitFullscreen(); }", true)
	_update_fullscreen_button()


func _update_fullscreen_button() -> void:
	if not has_node("CanvasLayer/Fullscreen"):
		return
	var btn: Button = $CanvasLayer/Fullscreen
	var fs := _is_fullscreen()
	_was_fullscreen = fs
	btn.text = "Exit Fullscreen" if fs else "Fullscreen"


## Positions the fullscreen button in the lower-right corner. When the story panel is open,
## it sits just to the left of the story sidebar; when closed or empty, it sits against the
## window's right edge margin.
func _update_fullscreen_button_layout() -> void:
	if not has_node("CanvasLayer/Fullscreen"):
		return
	var btn: Button = $CanvasLayer/Fullscreen
	var story: StoryPanel = get_node_or_null("CanvasLayer/StoryPanel")
	var right_margin: float = 16.0
	if story and story.visible:
		right_margin = absf(story.offset_left) + 16.0
	btn.offset_right = -right_margin
	btn.offset_left = -right_margin - 130.0
	btn.offset_bottom = -16.0
	btn.offset_top = -52.0


func _on_window_size_changed() -> void:
	_update_fullscreen_button()
	_update_fullscreen_button_layout()

func _init_webxr_ffr_hooks() -> void:
	if not OS.has_feature("web"):
		return
	var js: String = """
	(function() {
		if (window.__webxr_ffr_installed) return;
		window.__webxr_ffr_installed = true;
		if (typeof window.__webxr_ffr_level === 'undefined') {
			window.__webxr_ffr_level = 1.0;
		}
		if (typeof XRWebGLBinding !== 'undefined' && XRWebGLBinding.prototype) {
			var origCreate = XRWebGLBinding.prototype.createProjectionLayer;
			if (origCreate) {
				XRWebGLBinding.prototype.createProjectionLayer = function() {
					var layer = origCreate.apply(this, arguments);
					window.__webxr_projection_layer = layer;
					if ('fixedFoveation' in layer && window.__webxr_ffr_level !== null) {
						layer.fixedFoveation = window.__webxr_ffr_level;
						console.log('[WebXR FFR] Initialized projection layer fixedFoveation to', window.__webxr_ffr_level);
					}
					return layer;
				};
			}
		}
		if (navigator.xr && navigator.xr.requestSession) {
			var origReq = navigator.xr.requestSession.bind(navigator.xr);
			navigator.xr.requestSession = async function(mode, init) {
				init = init || {};
				init.optionalFeatures = init.optionalFeatures || [];
				if (!init.optionalFeatures.includes('high-fixed-foveation-level')) init.optionalFeatures.push('high-fixed-foveation-level');
				if (!init.optionalFeatures.includes('low-fixed-foveation-level')) init.optionalFeatures.push('low-fixed-foveation-level');
				var session = await origReq.call(navigator.xr, mode, init);
				window.__webxr_session = session;
				var origUpdate = session.updateRenderState.bind(session);
				session.updateRenderState = function(state) {
					if (state && state.layers) {
						window.__webxr_layers = state.layers;
						for (var i = 0; i < state.layers.length; i++) {
							var l = state.layers[i];
							if ('fixedFoveation' in l && window.__webxr_ffr_level !== null) {
								l.fixedFoveation = window.__webxr_ffr_level;
							}
						}
					}
					if (state && state.baseLayer) {
						window.__webxr_base_layer = state.baseLayer;
						if ('fixedFoveation' in state.baseLayer && window.__webxr_ffr_level !== null) {
							state.baseLayer.fixedFoveation = window.__webxr_ffr_level;
						}
					}
					return origUpdate(state);
				};
				return session;
			};
		}
		window.__webxr_set_ffr = function(lvl) {
			window.__webxr_ffr_level = lvl;
			var applied = false;
			if (window.__webxr_projection_layer && 'fixedFoveation' in window.__webxr_projection_layer) {
				window.__webxr_projection_layer.fixedFoveation = lvl;
				applied = true;
			}
			if (window.__webxr_layers) {
				for (var i = 0; i < window.__webxr_layers.length; i++) {
					var l = window.__webxr_layers[i];
					if ('fixedFoveation' in l) {
						l.fixedFoveation = lvl;
						applied = true;
					}
				}
			}
			if (window.__webxr_session && window.__webxr_session.renderState) {
				var rs = window.__webxr_session.renderState;
				if (rs.baseLayer && 'fixedFoveation' in rs.baseLayer) {
					rs.baseLayer.fixedFoveation = lvl;
					applied = true;
				}
				if (rs.layers) {
					for (var j = 0; j < rs.layers.length; j++) {
						if ('fixedFoveation' in rs.layers[j]) {
							rs.layers[j].fixedFoveation = lvl;
							applied = true;
						}
					}
				}
			}
			console.log('[WebXR FFR] Set fixedFoveation to ' + lvl + ' (applied: ' + applied + ')');
			return applied;
		};
	})();
	"""
	JavaScriptBridge.eval(js, true)


## Configures hardware Fixed Foveated Rendering (FFR) via WebXR on Meta Quest.
## Level ranges from 0.0 (disabled) to 1.0 (maximum peripheral reduction).
func _apply_webxr_fixed_foveation(enabled: bool, level: float) -> void:
	if not OS.has_feature("web"):
		return
	var fov_val: float = clampf(level if enabled else 0.0, 0.0, 1.0)
	var js: String = """
	(function(lvl) {
		try {
			if (typeof window.__webxr_set_ffr === 'function') {
				return window.__webxr_set_ffr(lvl);
			}
			return false;
		} catch (e) {
			console.warn('[WebXR FFR] Error setting ffr:', e);
			return false;
		}
	})(%.2f);
	""" % fov_val
	JavaScriptBridge.eval(js, true)


func _apply_webxr_viewport_scale(scale: float) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("""
		(function() {
			window.__webxr_viewport_scale = %f;
		})();
	""" % scale)


## Dynamically scales 3D viewport rendering resolution based on camera distance to the staged
## specimen bounding box surface. When far away, resolution scale is high (crisp overview, few
## total rays). When close up or inside the volume, a small patch of voxels magnifies across the
## screen; the scale smoothly lowers to prevent ray counts from exploding, holding high framerates
## while preserving voxel-grid fidelity.
func _update_adaptive_resolution(delta: float) -> void:
	var vp := get_viewport()
	var xr_active := vp.use_xr
	var cam: Camera3D = $XROrigin3D/XRCamera3D if xr_active else $Camera3D
	if cam == null:
		return

	var extents: Vector3 = $SpecimenStage.get_box_extents()
	var local_cam: Vector3 = $SpecimenStage.global_transform.affine_inverse() * cam.global_position
	var clamped: Vector3 = local_cam.clamp(-extents, extents)
	var dist_to_box: float = local_cam.distance_to(clamped)

	# Map distance to scale factor: u = 0.0 when touching or inside box, 1.0 at >= 1.5m
	var u := clampf(dist_to_box / 1.5, 0.0, 1.0)
	var t := pow(u, 0.75)

	var active_display: Dictionary = $CanvasLayer/DisplaySettingsPanel.get_display()
	var adaptive_xr: bool = bool(active_display.get("adaptive_steps", false))
	var motion_adaptive: bool = bool(active_display.get("motion_adaptive_steps", true))
	var adaptive_flat: bool = bool(active_display.get("adaptive_res_flat", true))

	if xr_active:
		# Godot's WebGL Compatibility renderer does not support multiview blit with scaling_3d_scale < 1.0;
		# it only upscales to the right eye, breaking stereoscopic rendering. Keep viewport scaling at 1.0.
		vp.scaling_3d_scale = 1.0
		var decoupled_pass: bool = bool(active_display.get("decoupled_volume_pass", false))
		if decoupled_pass:
			var vscale: float = float(active_display.get("volume_render_scale", 1.0))
			_apply_webxr_viewport_scale(vscale)

		var base_steps: int = int(_authored_quality.get("max_steps", Quality.XR_STEPS))
		if _user_touched_quality:
			base_steps = int(active_display.get("max_steps", Quality.XR_STEPS))
		else:
			base_steps = mini(base_steps, Quality.XR_STEPS)

		# If all adaptive stepping mechanisms are disabled, guarantee that the stage is restored to base_steps
		if not adaptive_xr and not motion_adaptive:
			if _current_xr_adaptive_steps != base_steps:
				_current_xr_adaptive_steps = base_steps
				var is_auto_step: bool = bool(active_display.get("auto_step_size", true))
				var step_sz: float = float(Quality.step_size_for(base_steps) if is_auto_step else active_display.get("step_size", 0.0025))
				var lut_subs: int = int(active_display.get("lut_substeps", 1))
				$SpecimenStage.apply_display({
					"max_steps": base_steps,
					"step_size": step_sz,
					"lut_substeps": lut_subs,
				})
			return

		var min_xr_steps := int(active_display.get("motion_step_floor", 48))
		var target_steps := base_steps
		if adaptive_xr:
			target_steps = int(round(lerpf(float(min_xr_steps), float(base_steps), t)))

		# Motion-adaptive quality throttling: during head rotation, rapid head movement,
		# or moving/rotating the specimen stage, reduce raymarching steps down toward
		# motion_step_floor to prevent dropping frames.
		if delta > 0.0001:
			var cur_cam_pos := cam.global_position
			var cur_cam_basis := cam.global_basis
			var cam_rot_delta := cur_cam_basis.inverse() * _last_xr_cam_rot
			var cam_rot_angle := cam_rot_delta.get_rotation_quaternion().get_angle()
			var cam_angular_speed := rad_to_deg(cam_rot_angle) / delta
			_last_xr_cam_pos = cur_cam_pos
			_last_xr_cam_rot = cur_cam_basis

			var stage_node: Node3D = $SpecimenStage
			var cur_stage_pos: Vector3 = stage_node.global_position
			var cur_stage_basis: Basis = stage_node.global_basis.orthonormalized()
			var stage_rot_delta: Basis = cur_stage_basis.inverse() * _last_stage_rot
			var stage_rot_angle: float = stage_rot_delta.get_rotation_quaternion().get_angle()
			var stage_angular_speed: float = rad_to_deg(stage_rot_angle) / delta
			var stage_linear_dist: float = cur_stage_pos.distance_to(_last_stage_pos)
			var stage_linear_speed: float = stage_linear_dist / delta
			var stage_equiv_speed: float = rad_to_deg(stage_linear_speed / maxf(dist_to_box, 0.25))
			_last_stage_pos = cur_stage_pos
			_last_stage_rot = cur_stage_basis

			var total_stage_speed := stage_angular_speed + stage_equiv_speed
			var total_motion_speed := maxf(cam_angular_speed, total_stage_speed)

			var motion_sens: float = float(active_display.get("motion_sensitivity", 20.0))
			var deadband: float = clampf(motion_sens * 0.4, 2.0, 15.0)
			var effective_speed := total_motion_speed if total_motion_speed > deadband else 0.0
			if effective_speed > _smoothed_angular_speed:
				_smoothed_angular_speed = effective_speed
			else:
				_smoothed_angular_speed = lerpf(_smoothed_angular_speed, effective_speed, clampf(14.0 * delta, 0.0, 1.0))
			if _smoothed_angular_speed < 1.0:
				_smoothed_angular_speed = 0.0

		if motion_adaptive and _smoothed_angular_speed > 0.0:
			var motion_pct: float = float(active_display.get("motion_step_percent", 40.0)) / 100.0
			if active_display.has("motion_step_floor") and not active_display.has("motion_step_percent"):
				motion_pct = clampf(float(active_display["motion_step_floor"]) / float(maxi(base_steps, 1)), 0.1, 1.0)
			var motion_sens: float = float(active_display.get("motion_sensitivity", 20.0))
			if motion_sens > 0.0:
				var motion_factor := clampf(_smoothed_angular_speed / motion_sens, 0.0, 1.0)
				var min_steps := maxf(16.0, float(base_steps) * motion_pct)
				target_steps = int(round(lerpf(float(target_steps), min_steps, motion_factor)))

		target_steps = int(round(float(target_steps) / 8.0) * 8.0)
		target_steps = clampi(target_steps, 16, base_steps)

		if target_steps != _current_xr_adaptive_steps:
			_current_xr_adaptive_steps = target_steps
			var is_auto_step: bool = bool(active_display.get("auto_step_size", true))
			var base_step_sz: float = float(Quality.step_size_for(target_steps) if is_auto_step else active_display.get("step_size", 0.0025))
			var step_sz: float = base_step_sz
			if not is_auto_step and motion_adaptive and target_steps < base_steps and target_steps > 0:
				step_sz = base_step_sz * (float(base_steps) / float(target_steps))
			var lut_subs: int = int(active_display.get("lut_substeps", 1))

			# Decouple lateral jitter: keep physical ray displacement constant during motion scaling
			var base_lat_jitter: float = float(active_display.get("lateral_jitter", 1.0))
			var lat_jitter: float = base_lat_jitter
			if target_steps < base_steps and target_steps > 0:
				lat_jitter = base_lat_jitter * (float(target_steps) / float(base_steps))

			$SpecimenStage.apply_display({
				"max_steps": target_steps,
				"step_size": step_sz,
				"lut_substeps": lut_subs,
				"lateral_jitter": lat_jitter,
			})
		return

	# In flat mode (mono rendering), scaling_3d_scale works reliably without stereo blit artifacts
	var decoupled_flat: bool = bool(active_display.get("decoupled_volume_pass", false))
	if decoupled_flat:
		var vscale: float = float(active_display.get("volume_render_scale", 1.0))
		vp.scaling_3d_scale = vscale
		return
	if not adaptive_flat:
		var manual_scale: float = float(active_display.get("scaling_3d_scale", 1.0))
		vp.scaling_3d_scale = manual_scale
		return

	var s_min: float
	var s_max: float
	if OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		s_min = 0.30
		s_max = 0.85
	else:
		s_min = 0.50
		s_max = 1.00

	var target_scale := lerpf(s_min, s_max, t)
	vp.scaling_3d_scale = lerpf(vp.scaling_3d_scale, target_scale, clampf(10.0 * delta, 0.0, 1.0))
