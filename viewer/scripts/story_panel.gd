## Displays one page of the bundle's story at a time, with Prev/Next navigation and a page
## counter. Story text is markdown, converted to BBCode via `MdToBBCode` before display. Inline
## images are fetched separately (HTTPRequest for http(s), Image.load for res://) and spliced
## into the RichTextLabel via `add_image` at their placeholder position -- RichTextLabel's own
## `[img]` tag uses ResourceLoader, which cannot fetch http(s) URLs. Emits
## `page_pinned(specimen_id)` whenever navigating to a page pins a specimen, so `main.gd` can
## stage it.
class_name StoryPanel
extends Control

signal page_pinned(specimen_id: String)

var _pages: Array = []
var _page_index: int = 0
var _base_url: String = ""

## Incremented every time a new page render starts; a pending image fetch checks this before
## touching the label so navigating away mid-fetch never overwrites a later page's text.
var _render_token: int = 0

static var _placeholder_re: RegEx


func _ready() -> void:
	$VBox/Buttons/Prev.pressed.connect(func(): show_page(_page_index - 1))
	$VBox/Buttons/Next.pressed.connect(func(): show_page(_page_index + 1))


## Loads `pages` (the manifest's `story` array) for display, resolving relative image paths in
## the markdown against `base_url`, and shows the first page.
func set_story(pages: Array, base_url: String) -> void:
	_pages = pages
	_base_url = base_url
	_page_index = 0
	visible = not _pages.is_empty()
	if not _pages.is_empty():
		_render_page(0, false)


## Navigates to `index` (clamped to the valid range). Emits `page_pinned` if the destination page
## pins a specimen.
func show_page(index: int) -> void:
	_render_page(index, true)


func _render_page(index: int, emit_pin: bool) -> void:
	if _pages.is_empty():
		return
	_page_index = clampi(index, 0, _pages.size() - 1)
	var page: Dictionary = _pages[_page_index]

	$VBox/Buttons/PageLabel.text = "%d / %d" % [_page_index + 1, _pages.size()]
	$VBox/Buttons/Prev.disabled = _page_index == 0
	$VBox/Buttons/Next.disabled = _page_index == _pages.size() - 1

	# Emit the pin before the (possibly async) text/image render so staging the specimen never
	# waits on image fetches.
	var specimen = page.get("specimen", null)
	if emit_pin and specimen != null:
		page_pinned.emit(str(specimen))

	_render_token += 1
	var token := _render_token
	var converted: Dictionary = MdToBBCode.convert(str(page.get("text", "")), _base_url)
	_apply_bbcode_with_images($VBox/Text, converted["text"], converted["images"], token)


## Renders `text` (with U+0001-delimited image placeholders, see `MdToBBCode`) into `label`,
## fetching each URL in `images` and splicing it in via `add_image` at the placeholder's
## position. A page that fetches its own images out of a since-superseded render checks
## `token` against the current `_render_token` before touching the label.
func _apply_bbcode_with_images(label: RichTextLabel, text: String, images: PackedStringArray, token: int) -> void:
	if _placeholder_re == null:
		_placeholder_re = RegEx.new()
		_placeholder_re.compile(MdToBBCode.IMG_PLACEHOLDER_PATTERN)

	label.clear()
	label.bbcode_enabled = true

	var last_end := 0
	for m in _placeholder_re.search_all(text):
		if token != _render_token:
			return
		var segment := text.substr(last_end, m.get_start() - last_end)
		if segment != "":
			label.append_text(segment)

		var idx := int(m.get_string(1))
		var url := images[idx] if idx < images.size() else ""
		await _append_image(label, url)

		last_end = m.get_end()

	if token != _render_token:
		return
	var tail := text.substr(last_end)
	if tail != "":
		label.append_text(tail)


## Fetches `url` and appends it as an image to `label`, or appends a short
## "[image unavailable: name]" note if the fetch or decode fails. Never raises.
func _append_image(label: RichTextLabel, url: String) -> void:
	if url == "":
		label.append_text("[image unavailable]")
		return

	var tex := await _load_image_texture(url)
	if tex == null:
		label.append_text("[image unavailable: %s]" % [url.get_file()])
		return
	label.add_image(tex)


## Loads `url` into an ImageTexture, or returns null on failure. `res://` paths load
## synchronously via `Image.load`; everything else (http/https/relative-web) is fetched via
## HTTPRequest.
func _load_image_texture(url: String) -> ImageTexture:
	if url.begins_with("res://"):
		var img := Image.new()
		if img.load(url) != OK:
			return null
		return ImageTexture.create_from_image(img)

	var request := HTTPRequest.new()
	add_child(request)
	var start_err := request.request(url)
	if start_err != OK:
		request.queue_free()
		return null

	var result: Array = await request.request_completed
	request.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if response_code < 200 or response_code >= 300:
		return null

	var img := Image.new()
	if _load_image_from_buffer(img, body, url) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Decodes `body` into `img`, dispatching on `url`'s extension (falls back to PNG).
func _load_image_from_buffer(img: Image, body: PackedByteArray, url: String) -> int:
	match url.get_extension().to_lower():
		"jpg", "jpeg":
			return img.load_jpg_from_buffer(body)
		"webp":
			return img.load_webp_from_buffer(body)
		"bmp":
			return img.load_bmp_from_buffer(body)
		"svg":
			return img.load_svg_from_buffer(body)
		_:
			return img.load_png_from_buffer(body)
