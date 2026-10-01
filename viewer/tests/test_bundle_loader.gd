extends GdUnitTestSuite

const FIXTURE := "res://tests/fixtures/tiny_bundle"


func test_validate_ok() -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(
		"res://tests/fixtures/tiny_bundle/manifest.json"))
	assert_that(BundleLoader.validate_manifest(manifest)).is_equal("")


func test_validate_wrong_version() -> void:
	assert_that(BundleLoader.validate_manifest({"version": 2, "title": "t", "specimens": [], "story": []}))\
		.contains("version")


func test_validate_unknown_pin() -> void:
	var m := {"version": 1, "title": "t",
		"specimens": [{"id": "a", "type": "volume", "data": "d.bin", "display": {}}],
		"story": [{"text": "x", "specimen": "nope"}]}
	assert_that(BundleLoader.validate_manifest(m)).contains("unknown specimen")


## Waits (via process_frame polling, with a generous frame cap) until `state[key]` is truthy.
## Used instead of gdUnit's assert_signal, which requires exact argument equality to match a
## signal emission — impractical here since `loaded`/`failed` carry Dictionary/String payloads.
func _wait_until(state: Dictionary, key: String, max_frames: int = 300) -> void:
	var frames := 0
	while not state.get(key, false) and frames < max_frames:
		await get_tree().process_frame
		frames += 1


func test_load_bundle_res_success() -> void:
	var loader: BundleLoader = auto_free(BundleLoader.new())
	add_child(loader)

	# Dictionaries are reference types, so mutating `state` inside the connected lambdas is
	# visible here afterwards (plain local vars captured by lambdas are captured by value).
	var state := {"loaded": false, "failed": false, "manifest": {}, "specimens": {}}
	loader.loaded.connect(func(m: Dictionary, s: Dictionary) -> void:
		state["manifest"] = m
		state["specimens"] = s
		state["loaded"] = true
	)
	loader.failed.connect(func(msg: String) -> void:
		state["message"] = msg
		state["failed"] = true
	)

	loader.load_bundle(FIXTURE)
	await _wait_until(state, "loaded")

	assert_that(state["failed"]).is_false()
	assert_that(state["loaded"]).is_true()
	var manifest: Dictionary = state["manifest"]
	var specimens: Dictionary = state["specimens"]
	assert_that(int(manifest.get("version"))).is_equal(1)
	assert_that(specimens.has("specimen_0")).is_true()
	var vol: WebVolumetricData = specimens["specimen_0"]
	assert_that(vol.get_texture()).is_not_null()


func test_load_bundle_res_missing_dir_fails() -> void:
	var loader: BundleLoader = auto_free(BundleLoader.new())
	add_child(loader)

	var state := {"loaded": false, "failed": false, "message": ""}
	loader.loaded.connect(func(_m: Dictionary, _s: Dictionary) -> void: state["loaded"] = true)
	loader.failed.connect(func(msg: String) -> void:
		state["message"] = msg
		state["failed"] = true
	)

	loader.load_bundle("res://tests/fixtures/does_not_exist")
	await _wait_until(state, "failed")

	assert_that(state["loaded"]).is_false()
	assert_that(state["failed"]).is_true()
	assert_that(state["message"]).is_not_equal("")


# Regression: with accept_gzip left on, HTTPRequest inflates a response the browser has
# already decompressed, which fails in stream_peer_gzip and reports "invalid JSON". A local
# python http.server never gzips, so this only reproduces against a real host like GitHub Pages.
func test_requests_do_not_ask_godot_to_inflate_gzip() -> void:
	var loader: BundleLoader = auto_free(BundleLoader.new())
	add_child(loader)
	var request: HTTPRequest = auto_free(loader.make_request())
	assert_bool(request.accept_gzip).is_false()

func test_load_bundle_emits_granular_progress_stages() -> void:
	var loader: BundleLoader = auto_free(BundleLoader.new())
	add_child(loader)

	var stages: Array[String] = []
	var ratios: Array[float] = []
	var state := {"loaded": false, "failed": false}

	loader.progress.connect(func(st: String, r: float) -> void:
		stages.append(st)
		ratios.append(r)
	)
	loader.loaded.connect(func(_m, _s): state["loaded"] = true)
	loader.failed.connect(func(_err): state["failed"] = true)

	loader.load_bundle(FIXTURE)
	await _wait_until(state, "loaded")

	assert_that(state["loaded"]).is_true()
	assert_that(ratios.size()).is_greater(3)
	assert_float(ratios.front()).is_equal(0.0)
	assert_float(ratios.back()).is_equal(1.0)
	# Check that stages contain descriptive stage names
	var joined := " ".join(stages)
	assert_str(joined).contains("Downloading")
	assert_str(joined).contains("Preparing")
	assert_str(joined).contains("Ready")


func test_volumetric_data_build_async_reports_slice_progress() -> void:
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/tiny_bundle/specimen_0.bin")
	var parsed := BinaryEnvelope.parse(bytes)
	var vol := WebVolumetricData.new()
	var reported: Array[float] = []

	var ok: bool = await vol.build_async(
		parsed["preamble"],
		bytes,
		parsed["offset"],
		get_tree(),
		func(p: float) -> void: reported.append(p)
	)

	assert_bool(ok).is_true()
	assert_that(reported.size()).is_greater_equal(2)
	assert_float(reported.back()).is_equal(1.0)
