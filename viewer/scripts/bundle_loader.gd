## Loads an ascribe-web content bundle (manifest.json + envelope-encoded specimen blobs).
##
## Two transports, selected by `base_url`:
##   - "res://..."  -> read synchronously via FileAccess (used by tests and any bundle shipped
##                     inside the exported pck). Still emits the same signals as the http path.
##   - anything else (a relative path, or an http(s) URL) -> fetched via HTTPRequest children.
##     URLs are always used relative to the current page (no CORS assumptions).
##
## On any failure at any stage, `failed(message)` is emitted with a human-readable message that
## names the offending file; `loaded` is never emitted after a failure.
class_name BundleLoader
extends Node

signal progress(stage: String, ratio: float)
signal loaded(manifest: Dictionary, specimens: Dictionary)
signal failed(message: String)

const MANIFEST_FILE := "manifest.json"


## Validates a parsed manifest dictionary. Returns "" if valid, else a human-readable error.
## Mirrors the bundler CLI's validate_manifest: version must be 1, specimens/story must be
## arrays, and every story page's `specimen` pin must reference a known specimen id.
static func validate_manifest(manifest: Dictionary) -> String:
	if not manifest.has("version"):
		return "manifest is missing 'version'"
	if int(manifest.get("version", -1)) != 1:
		return "unsupported manifest version %s (expected 1)" % [str(manifest.get("version"))]
	if not (manifest.get("specimens") is Array):
		return "manifest is missing a 'specimens' array"
	if not (manifest.get("story") is Array):
		return "manifest is missing a 'story' array"

	var specimen_ids := {}
	for spec in manifest["specimens"]:
		if not (spec is Dictionary) or not spec.has("id"):
			return "a specimen entry is missing 'id'"
		specimen_ids[spec["id"]] = true

	for page in manifest["story"]:
		if not (page is Dictionary):
			return "a story entry is not an object"
		var pin = page.get("specimen", null)
		if pin != null and not specimen_ids.has(pin):
			return "unknown specimen '%s' referenced in story" % [str(pin)]

	return ""


## Loads the bundle at `base_url` (a directory containing manifest.json and its data files).
func load_bundle(base_url: String) -> void:
	if base_url.begins_with("res://"):
		await _load_from_res(base_url)
	else:
		await _load_from_http(base_url)


func _join(base_url: String, name: String) -> String:
	if base_url.ends_with("/"):
		return base_url + name
	return base_url + "/" + name


func _load_from_res(base_url: String) -> void:
	var manifest_path := _join(base_url, MANIFEST_FILE)
	progress.emit("Loading manifest...", 0.0)

	if not FileAccess.file_exists(manifest_path):
		failed.emit("failed to read %s: file not found" % [manifest_path])
		return

	var text := FileAccess.get_file_as_string(manifest_path)
	var manifest = JSON.parse_string(text)
	if manifest == null or not (manifest is Dictionary):
		failed.emit("%s: invalid JSON" % [MANIFEST_FILE])
		return

	progress.emit("Manifest loaded", 0.05)
	await _finish_load(manifest, func(rel_path: String, on_dl_progress: Callable = Callable()) -> Variant:
		var full_path := _join(base_url, rel_path)
		if not FileAccess.file_exists(full_path):
			return {"error": "failed to read %s: file not found" % [rel_path]}
		if on_dl_progress.is_valid():
			on_dl_progress.call(1.0, 0, 0)
		return {"body": FileAccess.get_file_as_bytes(full_path)}
	)


func _load_from_http(base_url: String) -> void:
	var manifest_url := _join(base_url, MANIFEST_FILE)
	progress.emit("Loading manifest...", 0.0)

	var manifest_result := await _http_get(manifest_url)
	if manifest_result.has("error"):
		failed.emit("failed to fetch %s: %s" % [MANIFEST_FILE, manifest_result["error"]])
		return

	var manifest = JSON.parse_string(manifest_result["body"].get_string_from_utf8())
	if manifest == null or not (manifest is Dictionary):
		failed.emit("%s: invalid JSON" % [MANIFEST_FILE])
		return

	progress.emit("Manifest loaded", 0.05)
	await _finish_load(manifest, func(rel_path: String, on_dl_progress: Callable = Callable()) -> Variant:
		var result := await _http_get(_join(base_url, rel_path), on_dl_progress)
		if result.has("error"):
			return {"error": "failed to fetch %s: %s" % [rel_path, result["error"]]}
		return result
	)


## Shared validation + specimen decode loop, parameterized by a `fetch(rel_path, on_progress)`
## callable that returns {"body": PackedByteArray} or {"error": String}.
func _finish_load(manifest: Dictionary, fetch: Callable) -> void:
	var err := validate_manifest(manifest)
	if err != "":
		failed.emit("%s: %s" % [MANIFEST_FILE, err])
		return

	var specimens_list: Array = manifest.get("specimens", [])
	var total_specimens: int = specimens_list.size()
	if total_specimens == 0:
		loaded.emit(manifest, {})
		return

	var specimens := {}
	for i in range(total_specimens):
		var spec: Dictionary = specimens_list[i]
		var spec_id: String = spec.get("id", "specimen_%d" % i)
		var rel_path: String = spec.get("data", "")

		# Allocate a slice of total [0.05, 1.0] for this specimen:
		# Download: 75% of the specimen's time
		# Decode:   25% of the specimen's time
		var spec_base := 0.05 + 0.95 * (float(i) / float(total_specimens))
		var spec_span := 0.95 / float(total_specimens)
		var dl_span := spec_span * 0.75
		var decode_span := spec_span * 0.25

		var dl_callback := func(dl_fraction: float, downloaded: int, total: int) -> void:
			if dl_fraction >= 0.0:
				var overall_ratio := spec_base + dl_fraction * dl_span
				var label: String
				if total > 0:
					var dl_mb := float(downloaded) / 1048576.0
					var tot_mb := float(total) / 1048576.0
					label = "Downloading %s (%.1f / %.1f MB - %.0f%%)" % [spec_id, dl_mb, tot_mb, dl_fraction * 100.0]
				else:
					label = "Downloading %s (%.0f%%)" % [spec_id, dl_fraction * 100.0]
				progress.emit(label, overall_ratio)
			elif downloaded > 0:
				var dl_mb := float(downloaded) / 1048576.0
				var label := "Downloading %s (%.1f MB)" % [spec_id, dl_mb]
				var estimated_frac := 1.0 - exp(-float(downloaded) / (12.0 * 1048576.0))
				var overall_ratio := spec_base + estimated_frac * dl_span * 0.95
				progress.emit(label, overall_ratio)

		progress.emit("Downloading %s (0%%)" % [spec_id], spec_base)

		var fetched = await fetch.call(rel_path, dl_callback)
		if fetched.has("error"):
			failed.emit(fetched["error"])
			return

		var body: PackedByteArray = fetched["body"]
		var decode_base := spec_base + dl_span

		var decode_callback := func(dec_fraction: float) -> void:
			var overall_ratio := decode_base + dec_fraction * decode_span
			var label := "Preparing volume (%.0f%%)" % [dec_fraction * 100.0]
			progress.emit(label, overall_ratio)

		progress.emit("Preparing %s..." % [spec_id], decode_base)

		var obj = await _decode_specimen(spec, body, decode_callback)
		if obj == null:
			failed.emit("failed to decode %s: invalid or unsupported envelope" % [rel_path])
			return

		specimens[spec_id] = obj

	progress.emit("Ready", 1.0)
	loaded.emit(manifest, specimens)


## Decodes one specimen's envelope body into a WebVolumetricData or WebMeshData, or null on
## any failure. Volume decode batches across frames via WebVolumetricData.build_async.
func _decode_specimen(spec: Dictionary, body: PackedByteArray, on_progress: Callable = Callable()) -> Variant:
	var parsed := BinaryEnvelope.parse(body)
	if parsed.has("error"):
		push_error(parsed["error"])
		return null

	var preamble: Dictionary = parsed["preamble"]
	var offset: int = parsed["offset"]
	var kind: String = spec.get("type", "")

	if kind == "volume":
		var vol := WebVolumetricData.new()
		var ok: bool = await vol.build_async(preamble, body, offset, get_tree(), on_progress)
		return vol if ok else null

	if kind == "mesh":
		if on_progress.is_valid():
			on_progress.call(0.5)
		var mesh := WebMeshData.new()
		var ok: bool = mesh.set_from_bytes(preamble, body, offset)
		if on_progress.is_valid():
			on_progress.call(1.0)
		return mesh if ok else null

	push_error("BundleLoader: unknown specimen type '%s'" % [kind])
	return null


## Builds an HTTPRequest configured the way every bundle fetch needs it.
##
## `accept_gzip` must stay off. On web the browser transparently decompresses a gzipped
## response before Godot ever sees the body, but HTTPRequest still reads the
## `Content-Encoding: gzip` header and tries to inflate it a second time -- that fails inside
## stream_peer_gzip and hands back garbage, which surfaces as "manifest.json: invalid JSON".
## A local `python -m http.server` never compresses, so this only appears on a real static
## host; GitHub Pages gzips JSON by default.
func make_request() -> HTTPRequest:
	var request := HTTPRequest.new()
	request.accept_gzip = false
	return request


var _active_js_callbacks: Array[JavaScriptObject] = []


func _ensure_js_fetch_helper() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("""
		if (!window._ascribe_streaming_fetch) {
			window._ascribe_streaming_fetch = async function(url, onProgress, onSuccess, onError) {
				try {
					const response = await fetch(url);
					if (!response.ok) {
						if (onError) onError('HTTP ' + response.status);
						return;
					}
					const headerLength = response.headers.get('Content-Length');
					const contentLength = headerLength ? parseInt(headerLength, 10) : -1;
					const reader = response.body.getReader();
					let received = 0;
					const chunks = [];
					while (true) {
						const { done, value } = await reader.read();
						if (done) break;
						chunks.push(value);
						received += value.length;
						if (onProgress) {
							onProgress(received, contentLength);
						}
					}
					const combined = new Uint8Array(received);
					let offset = 0;
					for (const chunk of chunks) {
						combined.set(chunk, offset);
						offset += chunk.length;
					}
					if (onSuccess) {
						onSuccess(combined);
					}
				} catch (err) {
					if (onError) {
						onError(err.message || String(err));
					}
				}
			};
		}
	""", true)


func _fetch_web(url: String, on_progress: Callable = Callable()) -> Dictionary:
	_ensure_js_fetch_helper()

	var window = JavaScriptBridge.get_interface("window")
	if window == null or not window.has_method("_ascribe_streaming_fetch"):
		return {"error": "js_bridge_unavailable"}

	var result_box: Array = []
	var progress_cb: JavaScriptObject = null
	if on_progress.is_valid():
		progress_cb = JavaScriptBridge.create_callback(func(args: Array) -> void:
			if args.size() >= 2:
				var downloaded: int = int(args[0])
				var total: int = int(args[1])
				if total > 0:
					var fraction := clampf(float(downloaded) / float(total), 0.0, 1.0)
					on_progress.call(fraction, downloaded, total)
				else:
					on_progress.call(-1.0, downloaded, -1)
		)

	var success_cb: JavaScriptObject = JavaScriptBridge.create_callback(func(args: Array) -> void:
		if args.size() > 0 and JavaScriptBridge.is_js_buffer(args[0]):
			var bytes: PackedByteArray = JavaScriptBridge.js_buffer_to_packed_byte_array(args[0])
			result_box.append({"body": bytes})
		else:
			result_box.append({"error": "invalid buffer received from browser fetch"})
	)

	var error_cb: JavaScriptObject = JavaScriptBridge.create_callback(func(args: Array) -> void:
		var err_msg: String = str(args[0]) if args.size() > 0 else "unknown fetch error"
		result_box.append({"error": err_msg})
	)

	var cbs: Array[JavaScriptObject] = [success_cb, error_cb]
	if progress_cb != null:
		cbs.append(progress_cb)
	_active_js_callbacks.append_array(cbs)

	window.call("_ascribe_streaming_fetch", url, progress_cb, success_cb, error_cb)

	var tree := get_tree()
	while result_box.is_empty():
		if tree != null:
			await tree.process_frame
		else:
			break

	for cb in cbs:
		_active_js_callbacks.erase(cb)

	if result_box.is_empty():
		return {"error": "fetch timed out or aborted"}

	var outcome: Dictionary = result_box[0]
	if outcome.has("body") and on_progress.is_valid():
		var bsize: int = outcome["body"].size()
		on_progress.call(1.0, bsize, bsize)

	return outcome


## Performs a single HTTP GET, using streaming browser fetch on the Web platform,
## and HTTPRequest on desktop/headless native builds.
func _http_get(url: String, on_progress: Callable = Callable()) -> Dictionary:
	if OS.has_feature("web"):
		var web_res: Dictionary = await _fetch_web(url, on_progress)
		if not web_res.has("error") or web_res["error"] != "js_bridge_unavailable":
			return web_res
	return await _http_get_native(url, on_progress)


func _http_get_native(url: String, on_progress: Callable = Callable()) -> Dictionary:
	var request := make_request()
	add_child(request)

	var start_err := request.request(url)
	if start_err != OK:
		request.queue_free()
		return {"error": "could not start request (error %d)" % [start_err]}

	var response_box: Array = []
	if not on_progress.is_valid():
		var result: Array = await request.request_completed
		response_box.append(result)
	else:
		request.request_completed.connect(func(res: int, code: int, headers: PackedStringArray, body: PackedByteArray):
			response_box.append([res, code, headers, body])
		)

		var tree := get_tree()
		while response_box.is_empty():
			var downloaded := request.get_downloaded_bytes()
			var total := request.get_body_size()
			if downloaded > 0:
				if total > 0:
					var fraction := clampf(float(downloaded) / float(total), 0.0, 1.0)
					on_progress.call(fraction, downloaded, total)
				else:
					on_progress.call(-1.0, downloaded, -1)
			if tree != null:
				await tree.process_frame
			else:
				break

		if response_box.is_empty():
			var result: Array = await request.request_completed
			response_box.append(result)

	request.queue_free()

	if response_box.is_empty() or response_box[0].size() < 4:
		return {"error": "request failed or aborted"}

	var response_result: Array = response_box[0]
	var http_res: int = response_result[0]
	var response_code: int = response_result[1]
	var body: PackedByteArray = response_result[3]

	if http_res != HTTPRequest.RESULT_SUCCESS:
		return {"error": "HTTP request failed (result %d)" % [http_res]}

	if response_code < 200 or response_code >= 300:
		return {"error": "HTTP %d" % [response_code]}

	if on_progress.is_valid():
		on_progress.call(1.0, body.size(), body.size())

	return {"body": body}
