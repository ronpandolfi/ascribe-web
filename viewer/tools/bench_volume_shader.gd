## Automated GPU benchmark tool for the volume raymarching shader.
## Measures rendering frame times across quality tiers, outer steps, transfer-function sub-steps,
## jitter modes, filtering modes, and early ray termination.
##
## Usage:
##   godot --path viewer -s res://tools/bench_volume_shader.gd [--bundle=<path>]
##
extends SceneTree

var mat: ShaderMaterial


func _init() -> void:
	DisplayServer.window_set_vsync_mode(0)

	var bundle_arg := "res://tests/fixtures/singer_bundle"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bundle="):
			bundle_arg = arg.substr("--bundle=".length())

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)

	# Wait for specimen stage
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

	var mesh_inst: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_inst = child
			break

	if mesh_inst == null:
		push_error("bench: no MeshInstance3D staged")
		quit(1)
		return

	mat = mesh_inst.get_active_material(0) as ShaderMaterial
	if mat == null:
		push_error("bench: no ShaderMaterial on staged mesh")
		quit(1)
		return

	# Fixed inspection pose
	var cam: OrbitCamera = null
	for child in main.get_children():
		if child is OrbitCamera:
			cam = child
			break
	if cam:
		cam.yaw = 0.62
		cam.pitch = 0.22
		cam.distance = 0.55
		cam._sync_transform()

	for i in range(15):
		await process_frame

	var adapter := RenderingServer.get_video_adapter_name()
	var vendor := RenderingServer.get_video_adapter_vendor()

	print("\n=========================================================================================")
	print("VOLUME RAYMARCHING SHADER BENCHMARK")
	print("GPU:     %s (%s)" % [adapter, vendor])
	print("Dataset: %s" % [bundle_arg])
	print("=========================================================================================\n")

	print("### SUITE 1: Quality Slider Progression (Steps + Dynamic Sub-steps)")
	print("| Setting | Steps | Sub-steps | Step Size | Frame Time (ms) | FPS | Slowdown vs Floor |")
	print("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")
	var slider_configs = [
		{"name": "Slider @ 128 (Floor)", "steps": 128, "sub": 1, "sz": 0.010},
		{"name": "Slider @ 256 (Default XR)", "steps": 256, "sub": 8, "sz": 0.005},
		{"name": "Slider @ 512 (Mid)", "steps": 512, "sub": 32, "sz": 0.0025},
		{"name": "Slider @ 768 (High)", "steps": 768, "sub": 64, "sz": 0.0017},
		{"name": "Slider @ 1024 (Ultra)", "steps": 1024, "sub": 192, "sz": 0.00125},
	]
	var floor_ms := 0.0
	for cfg in slider_configs:
		var ms = await _measure(
			{
				"max_steps": cfg["steps"],
				"step_size": cfg["sz"],
				"lut_substeps": cfg["sub"],
				"lateral_jitter": 0.0
			}
		)
		if floor_ms == 0.0:
			floor_ms = ms
		var fps = 1000.0 / ms
		var ratio = ms / floor_ms
		print(
			(
				"| %-24s | %5d | %9d | %9.5f | %11.2f ms | %5.1f | %16.2fx |"
				% [cfg["name"], cfg["steps"], cfg["sub"], cfg["sz"], ms, fps, ratio]
			)
		)

	print("\n### SUITE 2: Isolated Outer March Steps (lut_substeps = 1, single lookup)")
	print("| Outer Steps | Step Size | Frame Time (ms) | FPS | Relative Slowdown |")
	print("| :---: | :---: | :---: | :---: | :---: |")
	var step_counts = [128, 192, 256, 384, 512, 768, 1024, 2048]
	var s128_ms := 0.0
	for s in step_counts:
		var sz = Quality.step_size_for(s)
		var ms = await _measure(
			{"max_steps": s, "step_size": sz, "lut_substeps": 1, "lateral_jitter": 0.0}
		)
		if s128_ms == 0.0:
			s128_ms = ms
		var fps = 1000.0 / ms
		var ratio = ms / s128_ms
		print(
			(
				"| %11d | %9.5f | %11.2f ms | %5.1f | %16.2fx |"
				% [s, sz, ms, fps, ratio]
			)
		)

	print("\n### SUITE 3: Isolated Sub-step Scaling (at 256 and 512 outer steps)")
	print("| Outer Steps | Sub-steps | Frame Time (ms) | FPS | Overhead over lut=1 |")
	print("| :---: | :---: | :---: | :---: | :---: |")
	for base_steps in [256, 512]:
		var sz = Quality.step_size_for(base_steps)
		var base_lut1_ms := 0.0
		for sub in [1, 2, 4, 8, 16, 32, 64]:
			var ms = await _measure(
				{
					"max_steps": base_steps,
					"step_size": sz,
					"lut_substeps": sub,
					"lateral_jitter": 0.0
				}
			)
			if base_lut1_ms == 0.0:
				base_lut1_ms = ms
			var fps = 1000.0 / ms
			var overhead = (ms - base_lut1_ms) / base_lut1_ms * 100.0
			print(
				(
					"| %11d | %9d | %11.2f ms | %5.1f | %18.1f%% |"
					% [base_steps, sub, ms, fps, overhead]
				)
			)

	print("\n### SUITE 4: Shader Features Overhead (at 256 steps, lut=1)")
	print("| Feature / Configuration | Frame Time (ms) | FPS | Overhead vs Baseline |")
	print("| :--- | :---: | :---: | :---: |")
	var base_feat = await _measure(
		{
			"max_steps": 256,
			"step_size": 0.005,
			"lut_substeps": 1,
			"lateral_jitter": 0.0,
			"smooth_sampling": false
		}
	)
	print(
		(
			"| Baseline (256 steps, lut=1) | %11.2f ms | %5.1f | %19.1f%% |"
			% [base_feat, 1000.0 / base_feat, 0.0]
		)
	)

	var with_jitter = await _measure(
		{
			"max_steps": 256,
			"step_size": 0.005,
			"lut_substeps": 1,
			"lateral_jitter": 4.0,
			"smooth_sampling": false
		}
	)
	var jitter_ovh = (with_jitter - base_feat) / base_feat * 100.0
	print(
		(
			"| With lateral_jitter = 4.0 | %11.2f ms | %5.1f | %+18.1f%% |"
			% [with_jitter, 1000.0 / with_jitter, jitter_ovh]
		)
	)

	var with_smooth = await _measure(
		{
			"max_steps": 256,
			"step_size": 0.005,
			"lut_substeps": 1,
			"lateral_jitter": 0.0,
			"smooth_sampling": true
		}
	)
	var smooth_ovh = (with_smooth - base_feat) / base_feat * 100.0
	print(
		(
			"| With smooth_sampling = true | %11.2f ms | %5.1f | %+18.1f%% |"
			% [with_smooth, 1000.0 / with_smooth, smooth_ovh]
		)
	)

	var with_shading = await _measure(
		{
			"max_steps": 256,
			"step_size": 0.005,
			"lut_substeps": 1,
			"lateral_jitter": 0.0,
			"smooth_sampling": false,
			"shading_enabled": true
		}
	)
	var shading_ovh = (with_shading - base_feat) / base_feat * 100.0
	print(
		(
			"| With shading_enabled = true | %11.2f ms | %5.1f | %+18.1f%% |"
			% [with_shading, 1000.0 / with_shading, shading_ovh]
		)
	)

	print("\n### SUITE 5: Early Ray Termination Threshold (at 512 steps, lut=1)")
	print("| saturation_cutoff | Frame Time (ms) | FPS |")
	print("| :---: | :---: | :---: |")
	for cut in [0.90, 0.95, 0.98, 0.995, 0.9999]:
		var ms = await _measure(
			{
				"max_steps": 512,
				"step_size": 0.0025,
				"lut_substeps": 1,
				"saturation_cutoff": cut
			}
		)
		print("| %17.4f | %11.2f ms | %5.1f |" % [cut, ms, 1000.0 / ms])

	print("\n=========================================================================================\n")
	quit()


func _measure(params: Dictionary) -> float:
	mat.set_shader_parameter("shading_enabled", false)
	mat.set_shader_parameter("smooth_sampling", false)
	mat.set_shader_parameter("lateral_jitter", 0.0)
	mat.set_shader_parameter("saturation_cutoff", 0.995)
	for k in params:
		mat.set_shader_parameter(k, params[k])
	# Warmup
	for i in range(12):
		await process_frame
	# Timed
	var num_frames := 50
	var t0 = Time.get_ticks_usec()
	for i in range(num_frames):
		await process_frame
	var t1 = Time.get_ticks_usec()
	return (t1 - t0) / 1000.0 / float(num_frames)
