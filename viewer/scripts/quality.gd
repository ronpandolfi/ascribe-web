## Picks a render-quality tier for the volume raymarch shader based on injected feature flags,
## so production callers pass real `OS.get_...` data while tests inject arrays directly.
class_name Quality
extends RefCounted

# Sampling density is the dominant quality control: too few steps and a ray skips through
# structure it should have integrated. The floor is 64 steps so that constrained mobile/VR
# devices can shed work and hold high framerates (72-90 Hz), while the range extends upward to 2048.
const MIN_USABLE_STEPS := 64
const MAX_STEPS := 2048

const DESKTOP_STEPS := 1024
const MOBILE_STEPS := 512
const XR_STEPS := 128

## Anchor points (max_steps, step_size) that `step_size_for` interpolates between. This is the
## single source of truth for the steps -> step_size mapping: both `pick_tier` (desktop/mobile/XR
## tiers) and the manual quality slider in `display_settings_panel.gd` go through it, so they can
## never disagree. Each tier constant above lands exactly on one of these anchors; values off an
## anchor are linearly interpolated between their neighbours.
##
## Step counts are paired with a step size such that `steps * step_size` stays around 1.3 -- far
## enough to cross the staged box, which is at most 1m on its longest axis. (The shader widens
## the step further if a particular ray is still longer than the budget covers.)
## Anchors are written out literally rather than in terms of the tier constants: when they were
## expressed as `[DESKTOP_STEPS, ...]`, raising a tier onto an existing anchor's step count
## silently produced a duplicate and returned the wrong step size.
const _STEP_SIZE_POINTS := [
	[64.0, 0.020],
	[128.0, 0.010],
	[256.0, 0.005],
	[512.0, 0.0025],
	[768.0, 0.00170],
	[1024.0, 0.00125],
	[2048.0, 0.000625],
]


## Returns the step size for a given step count, per `_STEP_SIZE_POINTS`. Reproduces the tier
## anchors exactly and linearly interpolates (or, past the ends, extrapolates flat) elsewhere.
static func step_size_for(steps: int) -> float:
	var s := float(steps)
	var pts := _STEP_SIZE_POINTS
	if s <= pts[0][0]:
		return pts[0][1]
	for i in range(pts.size() - 1):
		var a: Array = pts[i]
		var b: Array = pts[i + 1]
		if s <= b[0]:
			var t: float = (s - float(a[0])) / (float(b[0]) - float(a[0]))
			return lerpf(a[1], b[1], t)
	return pts[pts.size() - 1][1]


## Returns the LUT sub-step integration budget for a given step count.
## Higher step counts have the GPU headroom for deep sub-stepping; lower counts
## shed inner iterations so lowering the quality slider genuinely recovers framerate.
static func lut_substeps_for(steps: int) -> int:
	if steps <= 128:
		return 1
	elif steps <= 256:
		return 8
	elif steps <= 512:
		return 32
	elif steps <= 768:
		return 64
	else:
		return 192


## `features` mirrors `OS.has_feature(...)` checks the caller has already done (e.g.
## `["web_android"]` when `OS.has_feature("web_android")` is true). XR wins over mobile.
static func pick_tier(features: PackedStringArray, xr_active: bool) -> Dictionary:
	var steps := DESKTOP_STEPS
	var jitter := 1.0
	if xr_active:
		steps = XR_STEPS
		jitter = 0.0
	elif features.has("mobile") or features.has("web_android") or features.has("web_ios"):
		steps = MOBILE_STEPS
	# XR and mobile browsers run on unified mobile memory where dynamic inner loops cause
	# warp divergence and severe frame drops. Pin fallback lut_substeps to 1 on XR and mobile.
	var is_constrained := xr_active or features.has("mobile") or features.has("web_android") or features.has("web_ios")
	var lut_sub := 1 if is_constrained else lut_substeps_for(steps)
	return {
		"max_steps": steps,
		"step_size": step_size_for(steps),
		"auto_step_size": true,
		"lut_substeps": lut_sub,
		"lateral_jitter": jitter,
	}
