// Vendored from vr-start shaders/raymarching.gdshader (as of c45c7ce, "Overhaul raymarching
// shader: correct compositing, interval clipping, jitter, optional shading"). Note this is the
// overhauled root-level shader, NOT addons/volume_layered_shader/shaders/volume_shader.gdshader,
// which is the older copy this viewer originally vendored.
//
// Local changes:
// - `zoom` is replaced by `box_extents`: SpecimenStage stages non-cubic volumes in a box whose
//   largest axis is 1m, so the texture has to be normalized per-axis rather than by one scalar.
// - filter_linear instead of filter_linear_mipmap (no mipmaps are generated; WebGL2 mipmap
//   filtering of a mipless texture is undefined-ish).
// - the march step widens when max_steps * step_size cannot span the clipped interval, so a
//   volume is never truncated part-way through (the opacity correction follows the step
//   actually used, so density stays consistent).
// - the per-eye offset comes from an `eye_offsets` uniform indexed by VIEW_INDEX rather than
//   from EYE_OFFSET, which cannot be named at all under Godot 4.6's Compatibility (GLES3)
//   backend without breaking the mono shader variant. See the note in vertex().
shader_type spatial;
render_mode unshaded, cull_front, blend_premul_alpha;

const int MAX_EXCLUSION_PLANES = 4;
// Opacity is calibrated against this step size; changing step_size only
// changes quality, not the rendered density.
const float REFERENCE_STEP = 0.005;
// Upper bound for the transfer-function sub-stepping loop. The loop breaks at `lut_substeps`,
// but a constant bound keeps the shader friendly to drivers that dislike dynamic loop limits.
const int MAX_LUT_SUBSTEPS = 64;

uniform int max_steps = 256;
uniform float step_size = 0.005;
uniform bool enforce_exact_step_size = false;
uniform bool opacity_adaptive_stepping = false;
uniform float opacity_search_stride = 2.0;
uniform float volume_render_scale = 1.0;
uniform bool edge_aware_upscale = true;

uniform sampler3D texture_volume : source_color, filter_linear, repeat_disable;
uniform sampler3D texture_normals : filter_linear, repeat_disable;
uniform bool use_precomputed_normals = false;
uniform sampler2D gradient : filter_linear, repeat_disable;
// 2D pre-integrated transfer function LUT: maps (front_density^gamma, back_density^gamma)
// to integrated continuous (RGB, Opacity). Replaces dynamic sub-stepping loops with 1 fetch.
uniform sampler2D preintegrated_lut : filter_linear, repeat_disable;
uniform bool use_preintegrated_lut = true;
uniform float opacity = 1.0;
uniform float gamma = 1.0;
uniform float color_scalar = 1.0;
// Empty-space skipping parameters:
// ess_cutoff: mapped opacity threshold below which samples are treated as void (0.0 disables)
// ess_stride: multiplier applied to march_step when in void space (1.0 disables leap)
uniform float ess_cutoff = 0.002;
uniform float ess_stride = 2.0;
uniform sampler3D coarse_occupancy_grid : filter_linear, repeat_disable;
uniform bool use_coarse_grid = true;
uniform float coarse_leap_stride = 3.0;
// Half-extents (in object space) of the box the volume is staged in. 0.5 on every axis is a
// unit cube; SpecimenStage overrides this per-specimen so an anisotropic volume fills its box
// exactly on every axis instead of being stretched.
uniform vec3 box_extents = vec3(0.5, 0.5, 0.5);
uniform int num_exclusion_planes = 0;
// Planes in object (mesh-local) space; kept region is dot(p, xyz) <= w.
uniform vec4[MAX_EXCLUSION_PLANES] exclusion_planes;

// Smooths the hardware's trilinear reconstruction (see quintic_texel_coord). Off by default:
// on the close-up tested so far it made no measurable difference to the banding, so it is not
// worth the per-sample cost until a view is found where it helps.
uniform bool smooth_sampling = false;

// Diagnostic: reconstruct the volume with a manual trilinear blend (8 texelFetch + float32
// lerps) instead of the hardware sampler. Hardware texture filtering interpolates with
// fixed-point weights -- classically 8 bits of subtexel precision -- so a magnified texture
// reconstructs as ~256 discrete steps between adjacent texels, which shows up as banding.
// Doing the blend in the shader runs at full float precision. Costs 8 fetches per sample, so
// this exists to identify the artifact, not to ship enabled.
uniform bool manual_filter = false;

// Lateral (screen-plane) jitter: nudge each ray sideways by a random sub-voxel amount before
// it is traced, in units of the march step. This is a different thing from the start jitter
// below, which only moves samples along the ray. Neighbouring pixels otherwise trace nearly
// parallel rays whose sample grids are in nearly the same phase relative to a surface, so the
// phase error varies smoothly across the image and shows up as coherent moire. Offsetting
// sideways decorrelates that phase between adjacent pixels, trading the pattern for noise.
//
// On by default: it is the one thing that removes the coherent moire outright rather than
// reducing it, and a specimen that reads cleanly matters more than the grain it costs. Note the
// trade -- dithering is what makes the quality setting matter, since more steps means less
// per-ray error to scatter (grain 10.7 / 7.0 / 4.3 at 128 / 512 / 2048 steps). Set
// `display.lateral_jitter` to 0 in a manifest for content where the grain is not worth it.
uniform float lateral_jitter = 4.0;

// Diagnostic: scale of the per-ray start jitter (1.0 = one full march step, 0.0 = none).
// With jitter off, sampling-phase error becomes coherent banding instead of fine noise, which
// distinguishes "sampling position" artifacts from "reconstruction" artifacts.
uniform float jitter_amount = 1.0;

// How many times to evaluate the transfer function between consecutive density samples.
//
// The march samples density at discrete points and looks the LUT up at each one. When the LUT
// is steep, the colour and opacity between two consecutive samples are not well represented by
// either endpoint, so the result depends on exactly where the samples land -- which is a
// function of ray direction, so it varies across a curved surface and reads as banding. It also
// means the render is not step-invariant: brightness drifts as step size changes, even though
// the opacity correction is supposed to prevent that.
//
// Assuming density varies linearly between consecutive samples (true to first order), the fix
// is to integrate the LUT across that interval instead of point-sampling it. This is the cheap
// form of pre-integration (Engel et al. 2001): it costs extra 1D LUT lookups but no extra
// volume-texture fetches, which are the expensive part. 1 reproduces the old behaviour.
//
// Measured: it does reduce the step-dependence (brightness drift from 512 to 4096 steps falls
// from 2.4% to 1.7%) but it does NOT fix the banding, and face variation on the synthetic cube
// This is the sub-step *budget*, scaled by how far the sample moved along the transfer function
// and capped at MAX_LUT_SUBSTEPS, so samples in uniform material still cost a single lookup and
// only those crossing a steep part of the LUT spend the budget.
//
// Raising the cap from 16 to 64 is what finally removed the pixel-scale structure: at maximum
// gamma/opacity the residual falls from 2.148 to 0.930, and the fine grain component from 1.840
// to 0.463 -- with no dithering at all, so nothing is traded for noise. The saturation cutoff
// makes no further difference once the budget is this high (identical at 0.995 and 0.9999). That matters because the artifact converges with sub-step count:
// measured on the cube at maximum gamma/opacity, residual structure falls 9.81 -> 4.55 -> 2.73
// at 1 / 4 / 8 fixed sub-steps. The steeper the transfer function, the more are needed, which
// is why a fixed count that looked sufficient at default settings was not at extreme ones.
uniform int lut_substeps = 192;

// Opacity at which the march gives up: everything behind contributes less than (1 - this).
// Cutting off early is a performance win but quantises where a ray stops, which for a steep
// transfer function means the pixel's colour is decided at a sample boundary.
//
// 0.95 stops noticeably early: on a solid object the ray can saturate while still inside the
// surface's density ramp, so the pixel takes its colour from the ramp rather than from the
// material behind it -- and exactly where that happens shifts with sub-voxel phase, which is
// banding. 0.995 costs a longer march in dense volumes but removes most of that.
//
// This is easiest to see with a single-colour transfer function, where the colour factors out
// of the sum entirely: accumulated = sum(c * a_i * T_i) = c * total_opacity, so the pixel is
// c * alpha and the ONLY thing that can vary is alpha. On a solid every ray saturates, so alpha
// should be identical everywhere -- except the march stops at a discrete crossing and overshoots
// into [cutoff, 1] by however much the last increment happened to add. Measured on the cube's
// interior with a flat LUT: 12 distinct values at cutoff 0.95, 2 at 0.995, and exactly 1
// (std 0.000) at 0.9999. With a colour ramp there is a second, larger effect on top: *which*
// colour is picked depends on the density at which saturation occurred.
uniform float saturation_cutoff = 0.995;

// How a ray turns a column of density into a pixel.
//
//   0 -- emission/absorption: look the transfer function up at every sample and composite
//        front-to-back. Standard volume rendering, and what gives depth cues, but every
//        compositing-side artifact lives here: the first sample with meaningful alpha
//        dominates the pixel's colour, and a steep LUT is under-resolved between samples.
//   1 -- maximum intensity projection: reduce the ray to the largest density it crosses, then
//        apply the transfer function once. No compositing at all, so none of those artifacts
//        are possible. Loses depth ordering (a bright feature looks the same at any depth).
//   2 -- mean density along the ray, then the transfer function once. Like a radiograph;
//        keeps relative thickness but flattens structure.
uniform int projection_mode = 0;

uniform bool shading_enabled = false;
// Light direction in object space.
uniform vec3 light_dir = vec3(0.5, 0.7, 0.5);
uniform float ambient = 0.4;

// Per-view eye offset in view space, pushed by SpecimenStage while an XR session is running;
// both entries stay zero on desktop. See the note in vertex() for why this is not EYE_OFFSET.
uniform vec3 eye_offsets[2];

varying vec3 pos_local;
varying vec3 eye_pos_local;


void vertex() {
	pos_local = VERTEX;

	// Per-eye camera position in object space, so the fragment shader needs no matrix inverses.
	//
	// Upstream writes `(INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz`, but EYE_OFFSET cannot be
	// named here at all: Godot 4.6's Compatibility (GLES3) backend only declares `eye_offset` in
	// the multiview shader variant, so the mono variant fails to compile and nothing draws in a
	// normal browser tab. Dropping it entirely compiled, but then both eyes marched from the
	// same origin -- the image was identical in each eye, i.e. no stereo at all.
	//
	// VIEW_INDEX *does* compile in both variants, so the offsets come in as a uniform array
	// instead and are indexed per view. inverse(MODELVIEW_MATRIX) == inverse(MODEL) *
	// inverse(VIEW), so this is algebraically the same as upstream's two-step transform.
	eye_pos_local = (inverse(MODELVIEW_MATRIX) * vec4(eye_offsets[VIEW_INDEX], 1.0)).xyz;
}


// Clip the ray interval [t_near, t_far] to an axis-aligned box of the given
// half extents centered at the origin.
void clip_to_box(vec3 ro, vec3 rd, vec3 half_extents, inout float t_near, inout float t_far) {
	vec3 t_a = (-half_extents - ro) / rd;
	vec3 t_b = ( half_extents - ro) / rd;
	vec3 t_lo = min(t_a, t_b);
	vec3 t_hi = max(t_a, t_b);
	t_near = max(t_near, max(max(t_lo.x, t_lo.y), t_lo.z));
	t_far = min(t_far, min(min(t_hi.x, t_hi.y), t_hi.z));
}


// Reshape the position *within* a texel so the hardware's trilinear blend becomes smooth
// across voxel boundaries.
//
// Trilinear interpolation is continuous but its derivative is not: it kinks at every voxel
// boundary. Where a surface crosses the grid at a shallow angle those kinks line up into
// ridges whose spacing is the voxel pitch -- banding that does not move when you change the
// ray step size, because it is a property of the reconstruction, not of the sampling.
// Applying the quintic smoothstep 6t^5-15t^4+10t^3 to the in-texel fraction makes the
// interpolant C1-continuous, so the ridges have nothing to line up on.
vec3 quintic_texel_coord(vec3 uvw) {
	vec3 res = vec3(textureSize(texture_volume, 0));
	vec3 p = uvw * res - 0.5;
	vec3 base = floor(p);
	vec3 f = p - base;
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return (base + 0.5 + f) / res;
}


// Trilinear blend done in the shader at full float precision, bypassing the hardware sampler's
// fixed-point interpolation weights. See the `manual_filter` uniform.
float sample_volume_manual(vec3 uvw) {
	vec3 res = vec3(textureSize(texture_volume, 0));
	vec3 p = uvw * res - 0.5;
	vec3 base = floor(p);
	vec3 f = p - base;
	ivec3 i0 = ivec3(base);
	ivec3 hi = ivec3(res) - ivec3(1);

	float c000 = texelFetch(texture_volume, clamp(i0 + ivec3(0, 0, 0), ivec3(0), hi), 0).r;
	float c100 = texelFetch(texture_volume, clamp(i0 + ivec3(1, 0, 0), ivec3(0), hi), 0).r;
	float c010 = texelFetch(texture_volume, clamp(i0 + ivec3(0, 1, 0), ivec3(0), hi), 0).r;
	float c110 = texelFetch(texture_volume, clamp(i0 + ivec3(1, 1, 0), ivec3(0), hi), 0).r;
	float c001 = texelFetch(texture_volume, clamp(i0 + ivec3(0, 0, 1), ivec3(0), hi), 0).r;
	float c101 = texelFetch(texture_volume, clamp(i0 + ivec3(1, 0, 1), ivec3(0), hi), 0).r;
	float c011 = texelFetch(texture_volume, clamp(i0 + ivec3(0, 1, 1), ivec3(0), hi), 0).r;
	float c111 = texelFetch(texture_volume, clamp(i0 + ivec3(1, 1, 1), ivec3(0), hi), 0).r;

	float c00 = mix(c000, c100, f.x);
	float c10 = mix(c010, c110, f.x);
	float c01 = mix(c001, c101, f.x);
	float c11 = mix(c011, c111, f.x);
	return mix(mix(c00, c10, f.y), mix(c01, c11, f.y), f.z);
}


// Estimate the volume-density normal via central differences, in texture space.
vec3 density_normal(vec3 uvw) {
	vec3 eps = 1.0 / vec3(textureSize(texture_volume, 0));
	float dx = texture(texture_volume, uvw + vec3(eps.x, 0.0, 0.0)).r
	         - texture(texture_volume, uvw - vec3(eps.x, 0.0, 0.0)).r;
	float dy = texture(texture_volume, uvw + vec3(0.0, eps.y, 0.0)).r
	         - texture(texture_volume, uvw - vec3(0.0, eps.y, 0.0)).r;
	float dz = texture(texture_volume, uvw + vec3(0.0, 0.0, eps.z)).r
	         - texture(texture_volume, uvw - vec3(0.0, 0.0, eps.z)).r;
	return vec3(dx, dy, dz);
}


// Interleaved gradient noise: a low-discrepancy per-pixel value in [0, 1). Neighbouring pixels
// get very different values while the pattern stays even over larger areas, which makes it far
// less visible than a white-noise hash at the same amplitude.
float interleaved_gradient_noise(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}


void fragment() {
	vec3 ro = eye_pos_local;
	vec3 rd = normalize(pos_local - eye_pos_local);

	if (lateral_jitter > 0.0) {
		// Two axes spanning the plane perpendicular to the ray.
		vec3 up_ref = abs(rd.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 tangent = normalize(cross(up_ref, rd));
		vec3 bitangent = cross(rd, tangent);

		// Interleaved gradient noise rather than a sin-hash. A hash is white noise: its energy
		// is spread over all frequencies, and the low-frequency part is what the eye reads as
		// clumpy grain. IGN is low-discrepancy -- neighbouring pixels differ strongly while the
		// pattern stays even at larger scales -- so at equal amplitude it is markedly less
		// visible. The second sample is offset by the usual IGN decorrelation constant.
		float n1 = interleaved_gradient_noise(FRAGCOORD.xy);
		float n2 = interleaved_gradient_noise(FRAGCOORD.xy + vec2(5.588238, 5.588238));

		// Sample a disk rather than a square: a square offset biases toward its corners, which
		// shows up as directional structure in the grain.
		float angle = 6.2831853 * n1;
		float radius = sqrt(n2) * 0.5;
		vec2 offset = vec2(cos(angle), sin(angle)) * radius;
		ro += (tangent * offset.x + bitangent * offset.y) * step_size * lateral_jitter;
	}

	// Clip the ray to the staged box. Texture coordinates are normalized by the same extents,
	// so this one clip also keeps every sample inside [0, 1].
	float t_near = 0.0;
	float t_far = 1e20;
	clip_to_box(ro, rd, box_extents, t_near, t_far);

	// The kept region of the exclusion planes (dot <= w for every plane) is
	// convex, so it clips the interval exactly — no per-step tests needed.
	for (int i = 0; i < num_exclusion_planes; ++i) {
		vec4 plane = exclusion_planes[i];
		float denom = dot(rd, plane.xyz);
		float dist = plane.w - dot(ro, plane.xyz);
		if (abs(denom) < 1e-6) {
			if (dist < 0.0)
				t_far = -1.0; // origin excluded, ray parallel: nothing kept
		} else if (denom > 0.0) {
			t_far = min(t_far, dist / denom);
		} else {
			t_near = max(t_near, dist / denom);
		}
	}

	if (t_far <= t_near)
		discard;

	// Jitter the ray start (interleaved gradient noise) to break up the
	// banding of fixed-step sampling.
	float jitter = interleaved_gradient_noise(FRAGCOORD.xy) * jitter_amount;

	// max_steps * step_size is not guaranteed to span the clipped interval -- the desktop tier
	// reaches 1.28 but a 1m staged volume's diagonal can be ~1.39, so corner-on views would
	// drop the far side. Widen the step when the ray is longer than the budget covers, which
	// trades a little sampling detail for never truncating the volume.
	float span = max(t_far - t_near, 0.0);
	float eff_step_size = step_size / clamp(volume_render_scale, 0.25, 1.0);
	float march_step = max(eff_step_size, span / float(max_steps));
	if (enforce_exact_step_size) {
		march_step = eff_step_size;
	}

	// Opacity correction keeps density independent of step size.
	vec3 accumulated_color = vec3(0.0);
	float total_opacity = 0.0;
	// Density at the previous march step, so the transfer function can be integrated across the
	// interval between samples rather than point-sampled at each one.
	float prev_density = 0.0;
	bool has_prev = false;
	// Scalar projections (modes 1 and 2) reduce the ray before touching the transfer function.
	float max_density = 0.0;
	float density_sum = 0.0;
	float density_count = 0.0;

	float t = t_near + jitter * march_step;
	for (int i = 0; i < max_steps; ++i) {
		if (t > t_far)
			break;

		vec3 ray_pos = ro + rd * t;
		vec3 tex_sample_pt = (ray_pos / (2.0 * box_extents)) + vec3(0.5);

		// Coarse 3D occupancy grid skipping:
		// When searching for the volume boundary (total_opacity == 0.0), check the L1-cached
		// coarse 3D grid. If the coarse cell is empty, skip high-res sampling entirely.
		if (use_coarse_grid && total_opacity == 0.0) {
			float coarse_d = texture(coarse_occupancy_grid, tex_sample_pt).r;
			if (coarse_d < ess_cutoff) {
				t += march_step * coarse_leap_stride;
				continue;
			}
		}

		vec3 sample_pt = smooth_sampling ? quintic_texel_coord(tex_sample_pt) : tex_sample_pt;
		float density = manual_filter
			? sample_volume_manual(sample_pt)
			: texture(texture_volume, sample_pt).r;

		float current_step = march_step;
		if (opacity_adaptive_stepping) {
			if (total_opacity == 0.0) {
				current_step = march_step * opacity_search_stride;
			} else if (total_opacity > 0.70) {
				current_step = march_step * 1.5;
			}
		}
		float step_ratio = current_step / REFERENCE_STEP;

		if (projection_mode != 0) {
			max_density = max(max_density, density);
			density_sum += density;
			density_count += 1.0;
			prev_density = density;
			has_prev = true;
			t += current_step;
			continue;
		}

		// Empty-space skipping: sample the mapped transfer function to see if this interval
		// is optically empty. If mapped opacity is near zero, skip expensive normal calculations
		// and compositing, and take a larger stride through the void.
		float lut_from = pow(clamp(has_prev ? prev_density : density, 0.0, 1.0), gamma);
		float lut_to = pow(clamp(density, 0.0, 1.0), gamma);
		vec4 lut_sample;
		if (use_preintegrated_lut) {
			lut_sample = texture(preintegrated_lut, vec2(lut_from, lut_to));
		} else {
			lut_sample = texture(gradient, vec2(lut_to, 0.5));
		}

		float mapped_alpha = lut_sample.a * opacity;
		if (ess_stride > 1.0 && mapped_alpha < ess_cutoff) {
			prev_density = density;
			has_prev = true;
			t += current_step * ess_stride;
			continue;
		}

		vec3 shade_scale = vec3(1.0);
		if (shading_enabled) {
			vec3 n;
			if (use_precomputed_normals) {
				vec3 enc = texture(texture_normals, tex_sample_pt).rgb;
				n = enc * 2.0 - 1.0;
			} else {
				n = density_normal(tex_sample_pt);
			}
			if (dot(n, n) > 1e-8) {
				float diffuse = max(dot(normalize(n), normalize(light_dir)), 0.0);
				shade_scale = vec3(ambient + (1.0 - ambient) * diffuse);
			}
		}

		if (use_preintegrated_lut || lut_substeps <= 1) {
			float sample_opacity =
				1.0 - pow(1.0 - clamp(mapped_alpha, 0.0, 1.0), step_ratio);
			accumulated_color +=
				lut_sample.rgb * shade_scale * sample_opacity * (1.0 - total_opacity);
			total_opacity += sample_opacity * (1.0 - total_opacity);
		} else {
			float lut_delta = abs(lut_to - lut_from);
			int substeps = clamp(int(ceil(lut_delta * float(lut_substeps))), 1, MAX_LUT_SUBSTEPS);
			float sub_ratio = step_ratio / float(substeps);
			float d_from = has_prev ? prev_density : density;

			for (int k = 0; k < MAX_LUT_SUBSTEPS; ++k) {
				if (k >= substeps)
					break;
				// Midpoint of this sub-interval in density space.
				float u = (float(k) + 0.5) / float(substeps);
				float d = mix(d_from, density, u);
				vec4 sample = texture(gradient, vec2(pow(d, gamma), 0.5));
				float sample_opacity =
					1.0 - pow(1.0 - clamp(sample.a * opacity, 0.0, 1.0), sub_ratio);

				accumulated_color +=
					sample.rgb * shade_scale * sample_opacity * (1.0 - total_opacity);
				total_opacity += sample_opacity * (1.0 - total_opacity);
			}
		}

		prev_density = density;
		has_prev = true;
		t += current_step;

		// Saturated: everything behind this contributes nothing. Must break the march itself,
		// not just the sub-step loop, or the ray keeps stepping for no reason.
		if (total_opacity >= saturation_cutoff)
			break;
	}

	if (projection_mode != 0) {
		// One transfer-function lookup for the whole ray: no compositing, so no first-sample
		// dominance and nothing to under-resolve between samples.
		float scalar = projection_mode == 1
			? max_density
			: (density_count > 0.0 ? density_sum / density_count : 0.0);
		vec4 mapped = texture(gradient, vec2(pow(scalar, gamma), 0.5));
		float a = clamp(mapped.a * opacity, 0.0, 1.0);
		ALBEDO = mapped.rgb * a * color_scalar;   // premultiplied, to match the blend mode
		ALPHA = a;
	} else {

	// The march accumulates colour already weighted by each sample's opacity, so the output is
	// premultiplied. blend_premul_alpha composites that as `src.rgb + dst * (1 - src.a)`, which
	// is exactly right; plain alpha blending would multiply by alpha a second time, darkening
	// everything in proportion to its own transparency and amplifying sampling variation.
	ALBEDO = accumulated_color * color_scalar;
	ALPHA = total_opacity;
	}
}
