extends GdUnitTestSuite


func test_desktop_tier() -> void:
	var tier := Quality.pick_tier(PackedStringArray(), false)
	assert_that(tier["max_steps"]).is_equal(1024)
	assert_that(float(tier["step_size"])).is_equal(0.00125)


func test_mobile_web_android_tier() -> void:
	var tier := Quality.pick_tier(PackedStringArray(["web_android"]), false)
	assert_that(tier["max_steps"]).is_equal(512)
	assert_that(float(tier["step_size"])).is_equal(0.0025)


func test_mobile_web_ios_tier() -> void:
	var tier := Quality.pick_tier(PackedStringArray(["web_ios"]), false)
	assert_that(tier["max_steps"]).is_equal(512)
	assert_that(float(tier["step_size"])).is_equal(0.0025)


func test_mobile_flag_tier() -> void:
	var tier := Quality.pick_tier(PackedStringArray(["mobile"]), false)
	assert_that(tier["max_steps"]).is_equal(512)
	assert_that(float(tier["step_size"])).is_equal(0.0025)
	assert_that(tier["lut_substeps"]).is_equal(1)


func test_xr_tier() -> void:
	var tier := Quality.pick_tier(PackedStringArray(), true)
	assert_that(tier["max_steps"]).is_equal(128)
	assert_that(float(tier["step_size"])).is_equal(0.010)
	# XR decouples from inner sub-stepping to prevent warp divergence and hold framerate
	assert_that(tier["lut_substeps"]).is_equal(1)
	assert_that(float(tier["lateral_jitter"])).is_equal(0.0)


func test_xr_wins_over_mobile() -> void:
	var tier := Quality.pick_tier(PackedStringArray(["web_android"]), true)
	assert_that(tier["max_steps"]).is_equal(128)
	assert_that(float(tier["step_size"])).is_equal(0.010)


## step_size_for is the single source of truth behind pick_tier's step sizes; the display
## settings panel's manual quality slider goes through the same function, so a tier and the
## slider parked at that tier's step count must produce identical rendering.
func test_step_size_for_reproduces_every_tier() -> void:
	for xr in [true, false]:
		for features in [PackedStringArray(), PackedStringArray(["web_android"])]:
			var tier := Quality.pick_tier(features, xr)
			assert_that(float(tier["step_size"]))				.is_equal(float(Quality.step_size_for(tier["max_steps"])))


## Steps and step size are paired so the march spans the staged box (at most 1m on its longest
## axis, so ~1.74 across the diagonal of a unit cube) without the shader having to widen the step.
func test_every_tier_reaches_across_the_volume() -> void:
	for steps in [Quality.MIN_USABLE_STEPS, Quality.MOBILE_STEPS, Quality.XR_STEPS,
			Quality.DESKTOP_STEPS, Quality.MAX_STEPS]:
		var reach := float(steps) * Quality.step_size_for(steps)
		assert_float(reach).is_greater(1.2)


func test_step_size_for_interpolates_between_anchors() -> void:
	# 896 sits between the 768 and 1024 anchors, so it must fall strictly between their sizes.
	var mid := Quality.step_size_for(896)
	assert_that(mid).is_less(Quality.step_size_for(768))
	assert_that(mid).is_greater(Quality.step_size_for(1024))


## More steps must never mean a coarser step, or the slider would fight itself.
func test_step_size_decreases_monotonically_with_steps() -> void:
	var previous := 1.0
	for steps in range(Quality.MIN_USABLE_STEPS, Quality.MAX_STEPS + 1, 64):
		var size := Quality.step_size_for(steps)
		assert_that(size).is_less_equal(previous)
		previous = size


# Regression: the desktop tier used to land on the quality slider's maximum, so a user could
# only ever move quality *down* -- "increasing Quality does nothing" was literally true.
func test_slider_has_headroom_above_the_desktop_tier() -> void:
	assert_that(DisplaySettingsPanel.MAX_STEPS).is_greater(Quality.DESKTOP_STEPS)
	assert_that(float(Quality.step_size_for(2048))).is_equal(0.000625)
	# ...and a finer step than the desktop tier's, or the headroom would be cosmetic.
	assert_that(Quality.step_size_for(2048)).is_less(Quality.step_size_for(Quality.DESKTOP_STEPS))


# The slider must not offer settings that render unusably: its floor is the lowest quality worth
# shipping, not the lowest the shader can technically run.
func test_slider_floor_is_the_usable_minimum() -> void:
	assert_that(DisplaySettingsPanel.MIN_STEPS).is_equal(Quality.MIN_USABLE_STEPS)
	assert_that(Quality.MIN_USABLE_STEPS).is_greater_equal(64)
	# Every tier must sit inside the slider's travel, or the panel cannot show the current state.
	for steps in [Quality.MOBILE_STEPS, Quality.XR_STEPS, Quality.DESKTOP_STEPS]:
		assert_that(steps).is_greater_equal(DisplaySettingsPanel.MIN_STEPS)
		assert_that(steps).is_less_equal(DisplaySettingsPanel.MAX_STEPS)


func test_lut_substeps_for_scales_with_quality() -> void:
	assert_that(Quality.lut_substeps_for(128)).is_equal(1)
	assert_that(Quality.lut_substeps_for(256)).is_equal(8)
	assert_that(Quality.lut_substeps_for(512)).is_equal(32)
	assert_that(Quality.lut_substeps_for(1024)).is_equal(192)
