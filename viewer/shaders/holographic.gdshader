shader_type spatial;
// Self-lit: the look needs a sky to mirror and a light at a fixed angle, which the viewer's
// black, headlit scene does not have (in ascribe-xr it came from the scene's procedural sky and
// a fixed DirectionalLight3D). Both are computed here instead, in world space, so the rainbow
// band sweeps across the surface as the viewer orbits or turns the specimen.
render_mode unshaded, blend_mix, depth_draw_opaque, cull_back;

uniform float color_compression = 6.0;
// Direction *toward* the key light, in world space: ascribe-xr's light, coming from above-left.
uniform vec3 key_light_dir = vec3(-0.5, 0.75, -0.433);
uniform float rainbow_strength : hint_range(0.0, 2.0) = 1.0;
uniform float mirror_strength : hint_range(0.0, 1.0) = 0.5;
uniform float glow : hint_range(0.0, 1.0) = 0.125;
// Godot's ProceduralSkyMaterial defaults, which ascribe-xr's sky uses.
uniform vec3 sky_top : source_color = vec3(0.385, 0.454, 0.55);
uniform vec3 sky_horizon : source_color = vec3(0.646, 0.656, 0.67);
uniform vec3 ground_bottom : source_color = vec3(0.2, 0.169, 0.133);

// Function to convert HSV to RGB
// Not my creation, but slightly modified
vec3 hsv2rgb(vec3 hsv) {
    float h = hsv.x * color_compression; // 6.0 transitions the colors faster for us
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(mod(h, 2.0) - 1.0));
    vec3 rgb = vec3(0.0);

    if (0.0 <= h && h < 1.0) rgb = vec3(c, x, 0.0);
    else if (1.0 <= h && h < 2.0) rgb = vec3(x, c, 0.0);
    else if (2.0 <= h && h < 3.0) rgb = vec3(0.0, c, x);
    else if (3.0 <= h && h < 4.0) rgb = vec3(0.0, x, c);
    else if (4.0 <= h && h < 5.0) rgb = vec3(x, 0.0, c);
    else if (5.0 <= h && h < 6.0) rgb = vec3(c, 0.0, x);

    return rgb + (v - c);
}

/*
Converts a value in range [istart, istop] to a value in range [ostart, ostop].
*/
float range_lerp(float value, float istart, float istop, float ostart, float ostop) {
         return ostart + (ostop - ostart) * ((value - istart) / (istop - istart));
}

// A sky gradient seen along world-space direction `d`.
vec3 sky(vec3 d) {
	if (d.y >= 0.0) {
		return mix(sky_horizon, sky_top, smoothstep(0.0, 0.6, d.y));
	}
	return mix(sky_horizon, ground_bottom, smoothstep(0.0, 0.3, -d.y));
}

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);  // toward the camera
	vec3 l = normalize(key_light_dir);

	// The mirror: a grey metal (albedo 0.5) reflecting the sky.
	vec3 mirror = 0.5 * sky(reflect(-v, n)) * mirror_strength;

	// The original light() term, now from the fixed key light.
	vec3 reflection = reflect(l, v);
	float angle = dot(reflection, n);
	vec3 color = hsv2rgb(vec3(angle, 1.0, 1.0));
	if (angle > 0.6) {
		angle = clamp(range_lerp(angle, 0.6, 0.65, 1.0, 0.0), 0.0, 1.0);
	}
	vec3 rainbow = (color * max(angle, 0.0) + color * color * 0.25) * rainbow_strength;

	ALBEDO = mirror + rainbow + vec3(glow);
}
