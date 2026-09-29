## Main scene: loads a content bundle (from `?bundle=` on web, or a fixture bundle otherwise),
## stages its first specimen, and offers WebXR entry.
extends Node3D

var xr_interface: WebXRInterface
var _loader: BundleLoader
var _manifest: Dictionary = {}
var _specimens: Dictionary = {}
var _bundle_base_url: String = ""

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

	_loader = BundleLoader.new()
	add_child(_loader)
	_loader.progress.connect(_on_progress)
	_loader.loaded.connect(_on_loaded)
	_loader.failed.connect(_on_failed)

	$CanvasLayer/ProgressBar.value = 0.0
	_bundle_base_url = _resolve_bundle_url()
	_loader.load_bundle(_bundle_base_url)

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

	# Story panel gets its own pointer instance (same ray-cast mechanism, different quad); it has
	# no left-controller toggle wired so it simply stays visible.
	var story_pointer := $XROrigin3D/StoryPanelPointer
	story_pointer.right_controller = $XROrigin3D/RightController
	story_pointer.panel_quad = $XROrigin3D/StoryQuad
	story_pointer.panel_viewport = $XROrigin3D/StoryViewport
	story_pointer.laser_dot = $XROrigin3D/StoryLaserDot


## Connects both the desktop and in-VR display settings panels to the staged specimen. They are
## separate instances of the same `display_settings_panel.tscn` scene (one drawn to the desktop
## CanvasLayer, one rendered into the SubViewport behind the in-VR quad) so each can be adjusted
## independently without either mode fighting the other.
func _wire_display_panels() -> void:
	var on_display_changed := func(display: Dictionary) -> void:
		_user_touched_quality = true
		$SpecimenStage.apply_display(display)
	$CanvasLayer/DisplaySettingsPanel.display_changed.connect(on_display_changed)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.display_changed.connect(on_display_changed)

	# Only the in-VR panel offers a way out: in a headset there is no browser chrome to fall
	# back on, and the system gesture is not obvious to someone wearing it for the first time.
	var vr_panel: DisplaySettingsPanel = $XROrigin3D/PanelViewport/DisplaySettingsPanel
	vr_panel.set_exit_vr_visible(true)
	vr_panel.exit_vr_requested.connect(_exit_vr)

	# Edit mode is a local authoring affordance: it needs `ascribe-bundle serve --edit` behind
	# it, so it is opt-in via ?edit=1 and never offered for a bundle loaded from elsewhere.
	var desktop_panel: DisplaySettingsPanel = $CanvasLayer/DisplaySettingsPanel
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
	var xr_active := get_viewport().use_xr
	var tier := Quality.pick_tier(features, xr_active)
	if not _authored_quality.is_empty():
		# Honour the bundle's own setting, capped by what this device can afford.
		var steps: int = int(_authored_quality["max_steps"])
		if xr_active:
			steps = mini(steps, int(tier["max_steps"]))
		tier = {"max_steps": steps, "step_size": Quality.step_size_for(steps)}
	$SpecimenStage.apply_display(tier)
	$CanvasLayer/DisplaySettingsPanel.set_display(tier)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_display(tier)


## Feeds the staged volume the current per-eye offsets while an XR session is running, so the
## raymarch starts from the correct origin for each eye. The offsets are re-read every frame
## rather than cached: IPD can change between sessions, and some runtimes only report a
## meaningful value once tracking has settled.
func _process(_delta: float) -> void:
	_refresh_save_status()
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


func _on_progress(_stage: String, ratio: float) -> void:
	$CanvasLayer/ProgressBar.value = ratio * 100.0


func _on_loaded(manifest: Dictionary, specimens: Dictionary) -> void:
	_manifest = manifest
	_specimens = specimens
	$CanvasLayer/ProgressBar.visible = false

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
	# Show the bundle's own gamma/opacity on the panels. Without this the sliders sit at their
	# defaults while the render uses the manifest's values -- the panel lies about the current
	# state, and in edit mode saving would write the slider defaults over a tuned manifest.
	$CanvasLayer/DisplaySettingsPanel.set_display(spec_display)
	$XROrigin3D/PanelViewport/DisplaySettingsPanel.set_display(spec_display)
	_apply_quality_tier()

	var story: Array = manifest.get("story", [])
	$CanvasLayer/StoryPanel.set_story(story, _bundle_base_url)
	$XROrigin3D/StoryViewport/StoryPanel.set_story(story, _bundle_base_url)
	$XROrigin3D/StoryQuad.visible = not story.is_empty()
	_update_fullscreen_button_layout()


func _on_failed(message: String) -> void:
	$CanvasLayer/ProgressBar.visible = false
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
	$CanvasLayer/EnterVR.visible = true
	$CanvasLayer/Fullscreen.visible = true


func _on_session_started() -> void:
	get_viewport().use_xr = true
	$CanvasLayer/EnterVR.visible = false
	$CanvasLayer/Fullscreen.visible = false
	_apply_quality_tier()


func _on_session_ended() -> void:
	get_viewport().use_xr = false
	$CanvasLayer/Fullscreen.visible = true
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
