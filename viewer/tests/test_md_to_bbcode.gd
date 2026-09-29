extends GdUnitTestSuite


func test_header_h1_becomes_font_size_24() -> void:
	var result: Dictionary = MdToBBCode.convert("# Title", "img")
	assert_that(result["text"]).is_equal("[font_size=24]Title[/font_size]")


func test_header_h2_becomes_font_size_20() -> void:
	var result: Dictionary = MdToBBCode.convert("## Subtitle", "img")
	assert_that(result["text"]).is_equal("[font_size=20]Subtitle[/font_size]")


func test_bold_becomes_b_tag() -> void:
	var result: Dictionary = MdToBBCode.convert("this is **bold** text", "img")
	assert_that(result["text"]).is_equal("this is [b]bold[/b] text")


func test_italic_becomes_i_tag() -> void:
	var result: Dictionary = MdToBBCode.convert("this is *italic* text", "img")
	assert_that(result["text"]).is_equal("this is [i]italic[/i] text")


func test_image_url_joined_with_base_url() -> void:
	var result: Dictionary = MdToBBCode.convert("![alt](fig1.png)", "https://example.com/base")
	assert_that(result["images"]).is_equal(PackedStringArray(["https://example.com/base/fig1.png"]))


func test_image_replaced_with_indexed_placeholder() -> void:
	var result: Dictionary = MdToBBCode.convert("![alt](fig1.png)", "https://example.com/base")
	var re := RegEx.new()
	re.compile(MdToBBCode.IMG_PLACEHOLDER_PATTERN)
	var m := re.search(result["text"])
	assert_that(m).is_not_null()
	assert_that(int(m.get_string(1))).is_equal(0)


func test_plain_paragraphs_pass_through() -> void:
	var result: Dictionary = MdToBBCode.convert("Hello world.\n\nSecond paragraph.", "img")
	assert_that(result["text"]).is_equal("Hello world.\n\nSecond paragraph.")


func test_bbcode_hostile_input_is_escaped_first() -> void:
	var result: Dictionary = MdToBBCode.convert("literal [bracket] text", "img")
	assert_that(result["text"]).is_equal("literal [lb]bracket] text")


func test_bold_inside_escaped_brackets_still_bolds() -> void:
	# Escaping must happen before markdown conversion so real markdown syntax still converts
	# even when the surrounding text has literal brackets.
	var result: Dictionary = MdToBBCode.convert("[note] **bold**", "img")
	assert_that(result["text"]).is_equal("[lb]note] [b]bold[/b]")


func test_two_images_resolve_to_distinct_urls() -> void:
	var md := "![a](one.png)\n\n![b](sub/two.png)"
	var result: Dictionary = MdToBBCode.convert(md, "https://example.com/base")
	assert_that(result["images"]).is_equal(PackedStringArray([
		"https://example.com/base/one.png",
		"https://example.com/base/sub/two.png",
	]))

	var re := RegEx.new()
	re.compile(MdToBBCode.IMG_PLACEHOLDER_PATTERN)
	var matches := re.search_all(result["text"])
	assert_that(matches.size()).is_equal(2)
	assert_that(int(matches[0].get_string(1))).is_equal(0)
	assert_that(int(matches[1].get_string(1))).is_equal(1)


func test_literal_word_img_in_prose_is_untouched() -> void:
	var md := "The IMG tag is not an image placeholder here, and neither is IMG0 on its own."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal(md)
	assert_that(result["images"]).is_equal(PackedStringArray())


func test_soft_line_breaks_within_paragraph_collapse_to_spaces() -> void:
	var md := "First line of a paragraph.\nSecond line of the same paragraph.\nThird line."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("First line of a paragraph. Second line of the same paragraph. Third line.")


func test_hard_line_break_with_two_trailing_spaces_preserves_newline() -> void:
	var md := "First line with hard break.  \nSecond line."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("First line with hard break.\nSecond line.")


func test_hard_line_break_with_backslash_preserves_newline() -> void:
	var md := "First line with backslash break.\\\nSecond line."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("First line with backslash break.\nSecond line.")


func test_multiple_blank_lines_collapse_to_single_paragraph_break() -> void:
	var md := "Paragraph 1\n\n\n\nParagraph 2"
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("Paragraph 1\n\nParagraph 2")


func test_header_and_paragraph_stay_on_separate_lines() -> void:
	var md := "# Title\nFirst line of paragraph.\nSecond line."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("[font_size=24]Title[/font_size]\nFirst line of paragraph. Second line.")


func test_list_items_stay_on_separate_lines() -> void:
	var md := "The list:\n- First item\n- Second item"
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("The list:\n- First item\n- Second item")


func test_list_item_with_wrapped_line_collapses_to_space() -> void:
	var md := "- First item line 1\n  line 2\n- Second item"
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("- First item line 1 line 2\n- Second item")


func test_bold_spanning_across_line_break_formats_correctly() -> void:
	var md := "This is **bold\ntext** across lines."
	var result: Dictionary = MdToBBCode.convert(md, "img")
	assert_that(result["text"]).is_equal("This is [b]bold text[/b] across lines.")
