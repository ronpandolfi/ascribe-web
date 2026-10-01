## UI panel with sliders for gamma, opacity, and render quality (steps), along with an expandable
## Advanced panel for individual tuning of raymarching steps, step size, empty-space skipping (ESS),
## distance-adaptive scaling, surface shading, early termination, pre-integrated LUT, and dither.
## Emits `display_changed` with a display dictionary whenever any control changes.
class_name DisplaySettingsPanel
extends Control

signal display_changed(display: Dictionary)
signal exit_vr_requested
signal save_requested

const SAVE_TEXT := "Save view + settings"
const MIN_STEPS := Quality.MIN_USABLE_STEPS
const MAX_STEPS := Quality.MAX_STEPS

var is_vr := false
var _advanced_open := false

# Onready node references for basic controls
@onready var _gamma_label: Label = $VBox/GammaLabel
@onready var _gamma_slider: HSlider = $VBox/Gamma
@onready var _opacity_label: Label = $VBox/OpacityLabel
@onready var _opacity_slider: HSlider = $VBox/Opacity
@onready var _quality_label: Label = $VBox/QualityLabel
@onready var _quality_slider: HSlider = $VBox/Quality
@onready var _advanced_toggle: Button = $VBox/AdvancedToggle
@onready var _advanced_scroll: ScrollContainer = $VBox/AdvancedScroll
@onready var _exit_vr_btn: Button = $VBox/ExitVR
@onready var _save_btn: Button = $VBox/Save

# Onready node references for advanced controls
@onready var _max_steps_label: Label = $VBox/AdvancedScroll/AdvancedVBox/MaxStepsLabel
@onready var _max_steps_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/MaxSteps
@onready var _step_size_label: Label = $VBox/AdvancedScroll/AdvancedVBox/StepSizeLabel
@onready var _step_size_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/StepSize
@onready var _auto_step_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/AutoStepSize
@onready var _adaptive_steps_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/AdaptiveSteps
@onready var _shading_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/ShadingEnabled
@onready var _early_cutoff_label: Label = $VBox/AdvancedScroll/AdvancedVBox/EarlyCutoffLabel
@onready var _early_cutoff_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/EarlyCutoff

@onready var _ess_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/ESSEnabled
@onready var _ess_stride_label: Label = $VBox/AdvancedScroll/AdvancedVBox/ESSStrideLabel
@onready var _ess_stride_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/ESSStride
@onready var _ess_cutoff_label: Label = $VBox/AdvancedScroll/AdvancedVBox/ESSCutoffLabel
@onready var _ess_cutoff_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/ESSCutoff

@onready var _lut_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/PreintegratedLUT
@onready var _lut_substeps_label: Label = $VBox/AdvancedScroll/AdvancedVBox/LUTSubstepsLabel
@onready var _lut_substeps_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/LUTSubsteps
@onready var _jitter_label: Label = $VBox/AdvancedScroll/AdvancedVBox/JitterLabel
@onready var _jitter_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/Jitter
@onready var _lateral_dither_label: Label = $VBox/AdvancedScroll/AdvancedVBox/LateralDitherLabel
@onready var _lateral_dither_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/LateralDither

@onready var _ffr_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/FFREnabled
@onready var _ffr_label: Label = $VBox/AdvancedScroll/AdvancedVBox/FFRLevelLabel
@onready var _ffr_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/FFRLevel

@onready var _scale_3d_label: Label = $VBox/AdvancedScroll/AdvancedVBox/Scale3DLabel
@onready var _scale_3d_slider: HSlider = $VBox/AdvancedScroll/AdvancedVBox/Scale3D
@onready var _adaptive_flat_check: CheckBox = $VBox/AdvancedScroll/AdvancedVBox/AdaptiveResFlat


func _ready() -> void:
	_gamma_slider.min_value = 0.1
	_gamma_slider.max_value = 4.0
	_gamma_slider.value = 1.0
	_gamma_slider.value_changed.connect(func(v):
		_update_label(_gamma_label, "Gamma: %.2f" % v)
		_emit_changed()
	)

	_opacity_slider.min_value = 0.0
	_opacity_slider.max_value = 2.0
	_opacity_slider.value = 1.0
	_opacity_slider.value_changed.connect(func(v):
		_update_label(_opacity_label, "Opacity: %.2f" % v)
		_emit_changed()
	)

	_quality_slider.min_value = MIN_STEPS
	_quality_slider.max_value = MAX_STEPS
	_quality_slider.value = Quality.DESKTOP_STEPS

	_max_steps_slider.min_value = 16.0
	_max_steps_slider.max_value = MAX_STEPS
	_max_steps_slider.value = Quality.DESKTOP_STEPS
	_step_size_slider.min_value = 0.0005
	_step_size_slider.max_value = 0.05
	_step_size_slider.step = 0.00001
	_step_size_slider.value = Quality.step_size_for(Quality.DESKTOP_STEPS)
	_quality_slider.value_changed.connect(func(v):
		_update_label(_quality_label, "Quality: %d steps" % int(v))
		if _max_steps_slider and _max_steps_slider.value != v:
			_max_steps_slider.set_value_no_signal(v)
			_update_label(_max_steps_label, "Raymarch Steps: %d" % int(v))
		if _auto_step_check and _auto_step_check.button_pressed and _step_size_slider:
			var sz := Quality.step_size_for(int(v))
			_step_size_slider.set_value_no_signal(sz)
			_update_label(_step_size_label, "Step Size: %.4f" % sz)
		_emit_changed()
	)

	_advanced_toggle.pressed.connect(_on_advanced_toggled)

	# Raymarching sliders & checks
	_max_steps_slider.value_changed.connect(func(v):
		_update_label(_max_steps_label, "Raymarch Steps: %d" % int(v))
		if _quality_slider and _quality_slider.value != v:
			_quality_slider.set_value_no_signal(clampf(v, MIN_STEPS, MAX_STEPS))
			_update_label(_quality_label, "Quality: %d steps" % int(clampf(v, MIN_STEPS, MAX_STEPS)))
		if _auto_step_check.button_pressed and _step_size_slider:
			var sz := Quality.step_size_for(int(v))
			_step_size_slider.set_value_no_signal(sz)
			_update_label(_step_size_label, "Step Size: %.4f" % sz)
		_emit_changed()
	)

	_step_size_slider.value_changed.connect(func(v):
		_update_label(_step_size_label, "Step Size: %.4f" % v)
		_auto_step_check.set_pressed_no_signal(false)
		_emit_changed()
	)

	_auto_step_check.toggled.connect(func(pressed):
		if pressed:
			var sz := Quality.step_size_for(int(_max_steps_slider.value))
			_step_size_slider.set_value_no_signal(sz)
			_update_label(_step_size_label, "Step Size: %.4f" % sz)
		_emit_changed()
	)

	_adaptive_steps_check.toggled.connect(func(_p): _emit_changed())
	_shading_check.toggled.connect(func(_p): _emit_changed())

	_early_cutoff_slider.value_changed.connect(func(v):
		_update_label(_early_cutoff_label, "Early Ray Cutoff: %.3f" % v)
		_emit_changed()
	)

	# ESS controls
	_ess_check.toggled.connect(func(_p): _emit_changed())
	_ess_stride_slider.value_changed.connect(func(v):
		_update_label(_ess_stride_label, "ESS Leap Stride: %.1fx" % v)
		_emit_changed()
	)
	_ess_cutoff_slider.value_changed.connect(func(v):
		_update_label(_ess_cutoff_label, "ESS Alpha Cutoff: %.4f" % v)
		_emit_changed()
	)

	# Sampling controls
	_lut_check.toggled.connect(func(_p): _emit_changed())
	_lut_substeps_slider.value_changed.connect(func(v):
		_update_label(_lut_substeps_label, "LUT Sub-steps: %d" % int(v))
		_emit_changed()
	)
	_jitter_slider.value_changed.connect(func(v):
		_update_label(_jitter_label, "Ray Start Jitter: %.1f" % v)
		_emit_changed()
	)
	_lateral_dither_slider.value_changed.connect(func(v):
		_update_label(_lateral_dither_label, "Lateral Dither: %.1f" % v)
		_emit_changed()
	)

	# XR controls
	_ffr_check.toggled.connect(func(_p): _emit_changed())
	_ffr_slider.value_changed.connect(func(v):
		_update_label(_ffr_label, "FFR Level: %.1f" % v)
		_emit_changed()
	)

	# Viewport controls
	_scale_3d_slider.value_changed.connect(func(v):
		_update_label(_scale_3d_label, "Flat 3D Scale: %.2f" % v)
		_emit_changed()
	)
	_adaptive_flat_check.toggled.connect(func(_p): _emit_changed())

	_exit_vr_btn.pressed.connect(func(): exit_vr_requested.emit())
	_save_btn.pressed.connect(func(): save_requested.emit())
	_save_btn.visible = false
	_exit_vr_btn.visible = false

	_refresh_labels()


func _on_advanced_toggled() -> void:
	_advanced_open = not _advanced_open
	_advanced_scroll.visible = _advanced_open
	_advanced_toggle.text = "Advanced Settings [-]" if _advanced_open else "Advanced Settings [+]"

	if not is_vr and get_parent() is CanvasLayer:
		offset_bottom = offset_top + (560.0 if _advanced_open else 260.0)
		offset_right = offset_left + (280.0 if _advanced_open else 240.0)


func _update_label(lbl: Label, text: String) -> void:
	if lbl:
		lbl.text = text


func _refresh_labels() -> void:
	_update_label(_gamma_label, "Gamma: %.2f" % _gamma_slider.value)
	_update_label(_opacity_label, "Opacity: %.2f" % _opacity_slider.value)
	_update_label(_quality_label, "Quality: %d steps" % int(_quality_slider.value))
	_update_label(_max_steps_label, "Raymarch Steps: %d" % int(_max_steps_slider.value))
	_update_label(_step_size_label, "Step Size: %.4f" % _step_size_slider.value)
	_update_label(_early_cutoff_label, "Early Ray Cutoff: %.3f" % _early_cutoff_slider.value)
	_update_label(_ess_stride_label, "ESS Leap Stride: %.1fx" % _ess_stride_slider.value)
	_update_label(_ess_cutoff_label, "ESS Alpha Cutoff: %.4f" % _ess_cutoff_slider.value)
	_update_label(_lut_substeps_label, "LUT Sub-steps: %d" % int(_lut_substeps_slider.value))
	_update_label(_jitter_label, "Ray Start Jitter: %.1f" % _jitter_slider.value)
	_update_label(_lateral_dither_label, "Lateral Dither: %.1f" % _lateral_dither_slider.value)
	_update_label(_ffr_label, "FFR Level: %.1f" % _ffr_slider.value)
	_update_label(_scale_3d_label, "Flat 3D Scale: %.2f" % _scale_3d_slider.value)


func _emit_changed() -> void:
	clear_save_status()
	display_changed.emit(get_display())


func clear_save_status() -> void:
	if _save_btn and _save_btn.text != SAVE_TEXT:
		_save_btn.text = SAVE_TEXT


func get_display() -> Dictionary:
	var steps: int = int(_max_steps_slider.value if _max_steps_slider else $VBox/Quality.value)
	var step_sz: float = float(_step_size_slider.value if _step_size_slider else Quality.step_size_for(steps))
	var lut_sub: int = int(_lut_substeps_slider.value if _lut_substeps_slider else (1 if is_vr else Quality.lut_substeps_for(steps)))
	var ess_on: bool = _ess_check.button_pressed if _ess_check else true
	var ess_s: float = float(_ess_stride_slider.value if _ess_stride_slider else 2.0) if ess_on else 1.0
	var ess_c: float = float(_ess_cutoff_slider.value if _ess_cutoff_slider else 0.002) if ess_on else 0.0

	return {
		"gamma": _gamma_slider.value if _gamma_slider else $VBox/Gamma.value,
		"opacity": _opacity_slider.value if _opacity_slider else $VBox/Opacity.value,
		"max_steps": steps,
		"step_size": step_sz,
		"auto_step_size": _auto_step_check.button_pressed if _auto_step_check else false,
		"adaptive_steps": _adaptive_steps_check.button_pressed if _adaptive_steps_check else true,
		"shading_enabled": _shading_check.button_pressed if _shading_check else false,
		"saturation_cutoff": float(_early_cutoff_slider.value if _early_cutoff_slider else 0.995),
		"ess_enabled": ess_on,
		"ess_stride": ess_s,
		"ess_cutoff": ess_c,
		"use_preintegrated_lut": _lut_check.button_pressed if _lut_check else true,
		"lut_substeps": lut_sub,
		"jitter_amount": float(_jitter_slider.value if _jitter_slider else 1.0),
		"lateral_jitter": float(_lateral_dither_slider.value if _lateral_dither_slider else 0.0),
		"ffr_enabled": _ffr_check.button_pressed if _ffr_check else true,
		"ffr_level": float(_ffr_slider.value if _ffr_slider else 1.0),
		"scaling_3d_scale": float(_scale_3d_slider.value if _scale_3d_slider else 1.0),
		"adaptive_res_flat": _adaptive_flat_check.button_pressed if _adaptive_flat_check else true,
	}


func set_display(display: Dictionary) -> void:
	if display.has("gamma"):
		var g := float(display["gamma"])
		$VBox/Gamma.set_value_no_signal(g)
		_update_label(_gamma_label, "Gamma: %.2f" % g)

	if display.has("opacity"):
		var o := float(display["opacity"])
		$VBox/Opacity.set_value_no_signal(o)
		_update_label(_opacity_label, "Opacity: %.2f" % o)

	if display.has("max_steps"):
		var steps := int(display["max_steps"])
		$VBox/Quality.set_value_no_signal(clampf(steps, MIN_STEPS, MAX_STEPS))
		_update_label(_quality_label, "Quality: %d steps" % int(clampf(steps, MIN_STEPS, MAX_STEPS)))
		if _max_steps_slider:
			_max_steps_slider.set_value_no_signal(steps)
			_update_label(_max_steps_label, "Raymarch Steps: %d" % steps)
		if display.has("step_size") and _step_size_slider:
			var sz := float(display["step_size"])
			_step_size_slider.set_value_no_signal(sz)
			_update_label(_step_size_label, "Step Size: %.4f" % sz)
		elif _auto_step_check and _auto_step_check.button_pressed and _step_size_slider:
			var sz := Quality.step_size_for(steps)
			_step_size_slider.set_value_no_signal(sz)
			_update_label(_step_size_label, "Step Size: %.4f" % sz)

	if display.has("step_size") and not display.has("max_steps") and _step_size_slider:
		var sz := float(display["step_size"])
		_step_size_slider.set_value_no_signal(sz)
		_update_label(_step_size_label, "Step Size: %.4f" % sz)

	if display.has("auto_step_size") and _auto_step_check:
		_auto_step_check.set_pressed_no_signal(bool(display["auto_step_size"]))
	if display.has("adaptive_steps") and _adaptive_steps_check:
		_adaptive_steps_check.set_pressed_no_signal(bool(display["adaptive_steps"]))
	if display.has("shading_enabled") and _shading_check:
		_shading_check.set_pressed_no_signal(bool(display["shading_enabled"]))
	if display.has("saturation_cutoff") and _early_cutoff_slider:
		var c := float(display["saturation_cutoff"])
		_early_cutoff_slider.set_value_no_signal(c)
		_update_label(_early_cutoff_label, "Early Ray Cutoff: %.3f" % c)
	if display.has("ess_enabled") and _ess_check:
		_ess_check.set_pressed_no_signal(bool(display["ess_enabled"]))
	if display.has("ess_stride") and _ess_stride_slider:
		var s := float(display["ess_stride"])
		_ess_stride_slider.set_value_no_signal(s)
		_update_label(_ess_stride_label, "ESS Leap Stride: %.1fx" % s)
	if display.has("ess_cutoff") and _ess_cutoff_slider:
		var cut := float(display["ess_cutoff"])
		_ess_cutoff_slider.set_value_no_signal(cut)
		_update_label(_ess_cutoff_label, "ESS Alpha Cutoff: %.4f" % cut)
	if display.has("use_preintegrated_lut") and _lut_check:
		_lut_check.set_pressed_no_signal(bool(display["use_preintegrated_lut"]))
	if display.has("lut_substeps") and _lut_substeps_slider:
		var l := int(display["lut_substeps"])
		_lut_substeps_slider.set_value_no_signal(l)
		_update_label(_lut_substeps_label, "LUT Sub-steps: %d" % l)
	if display.has("jitter_amount") and _jitter_slider:
		var j := float(display["jitter_amount"])
		_jitter_slider.set_value_no_signal(j)
		_update_label(_jitter_label, "Ray Start Jitter: %.1f" % j)
	if display.has("lateral_jitter") and _lateral_dither_slider:
		var d := float(display["lateral_jitter"])
		_lateral_dither_slider.set_value_no_signal(d)
		_update_label(_lateral_dither_label, "Lateral Dither: %.1f" % d)
	if display.has("ffr_enabled") and _ffr_check:
		_ffr_check.set_pressed_no_signal(bool(display["ffr_enabled"]))
	if display.has("ffr_level") and _ffr_slider:
		var lvl := float(display["ffr_level"])
		_ffr_slider.set_value_no_signal(lvl)
		_update_label(_ffr_label, "FFR Level: %.1f" % lvl)
	if display.has("scaling_3d_scale") and _scale_3d_slider:
		var sc := float(display["scaling_3d_scale"])
		_scale_3d_slider.set_value_no_signal(sc)
		_update_label(_scale_3d_label, "Flat 3D Scale: %.2f" % sc)
	if display.has("adaptive_res_flat") and _adaptive_flat_check:
		_adaptive_flat_check.set_pressed_no_signal(bool(display["adaptive_res_flat"]))


func set_exit_vr_visible(shown: bool) -> void:
	$VBox/ExitVR.visible = shown
	is_vr = shown


func set_edit_enabled(enabled: bool) -> void:
	$VBox/Save.visible = enabled


func set_save_status(text: String) -> void:
	$VBox/Save.text = text
