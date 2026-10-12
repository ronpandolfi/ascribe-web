## Dev harness for shader A/B captures. Loads the main scene, waits for the volume to actually
## stage, parks the orbit camera at a fixed close-up pose, and lets --write-movie capture a
## deterministic frame -- so two shader or quality variants can be compared numerically instead
## of by eye.
##
##   godot --path viewer --quit-after 4000 --fixed-fps 30 --write-movie out/p.png ##       -s res://tools/shader_probe.gd -- --bundle=http://localhost:8060/singer_bundle ##       --param=max_steps:512 --param=step_size:0.0025
##
## --param overrides a shader uniform on the staged material (repeatable). It is needed because
## the startup quality tier overwrites whatever the manifest asked for.
##
## Note it waits on the staged mesh rather than a frame count: --write-movie advances frames far
## faster than real time, so a fixed wait outruns the bundle fetch.
extends SceneTree


func _init() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	# --write-movie advances frames far faster than real time, so waiting a fixed number of
	# frames outruns the fetch. Poll for the staged volume instead.
	var stage: Node = main.get_node("SpecimenStage")
	var waited := 0
	while waited < 20000:
		var staged := false
		for child in stage.get_children():
			if child is MeshInstance3D:
				staged = true
		if staged:
			break
		await process_frame
		waited += 1
	print("probe: staged after ", waited, " frames")
	var cam: OrbitCamera = main.get_node("OrbitCamera") if main.has_node("OrbitCamera") else null
	if cam == null:
		for child in main.get_children():
			if child is OrbitCamera:
				cam = child
	if cam == null:
		push_error("probe: no OrbitCamera in main scene")
		quit(1)
		return
	# Report the pose the viewer itself arrived at (from --view= or the manifest's saved view)
	# before overriding it, so the loaded framing can be verified.
	print("probe: loaded pose ", cam.pose_string())

	# main.gd already applies any --view=; only fall back to the default close-up when none
	# was given, so a pose captured from a real session reproduces exactly.
	var has_view := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			has_view = true
	if not has_view:
		cam.yaw = 0.62
		cam.pitch = 0.22
		cam.distance = 0.55
		cam._sync_transform()
	print("probe: pose ", cam.pose_string())

	# Override shader params from the command line: -- --param=name:value (repeatable).
	# The startup quality tier overwrites whatever the manifest asked for, so poke the
	# material directly.
	var mesh: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh = child
	# A staged mesh has a StandardMaterial3D, which has no shader uniforms to poke.
	var mat := mesh.get_surface_override_material(0) as ShaderMaterial
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--param=") and mat != null:
			var kv := arg.substr("--param=".length()).split(":")
			var name := kv[0]
			var value: Variant
			if kv[1] == "true" or kv[1] == "false":
				value = kv[1] == "true"
			elif name == "max_steps":
				value = int(kv[1])
			else:
				value = float(kv[1])
			mat.set_shader_parameter(name, value)
			print("probe: set ", name, " = ", value)
	for i in range(60):
		await process_frame

	# --save exercises edit mode's write-back path (needs `ascribe-bundle serve --edit`).
	for arg in OS.get_cmdline_user_args():
		if arg == "--save":
			print("probe: saving settings")
			await main._save_bundle_settings()
			for i in range(30):
				await process_frame
	quit()
