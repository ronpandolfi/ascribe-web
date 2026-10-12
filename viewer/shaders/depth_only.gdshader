// Writes depth and nothing else. MeshSurfaceMaterial draws this ahead of a translucent mesh so
// that only the nearest surface passes the depth test -- the Compatibility (WebGL2) renderer
// ignores TRANSPARENCY_ALPHA_DEPTH_PRE_PASS, so without it the mesh's own back layers show through.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_always, blend_mix, shadows_disabled;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
