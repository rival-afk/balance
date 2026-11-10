shader_type canvas_item;

// Тёмный войлок верстака: центр светлее, края гасятся (виньетка),
// лёгкий перекрёстный «ткацкий» узор из войлока.
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p * vec2(0.82, 1.0));
	float vign = smoothstep(1.25, 0.15, d);
	vec3 center = vec3(0.098, 0.098, 0.118);
	vec3 edge = vec3(0.055, 0.056, 0.072);
	vec3 base = mix(edge, center, vign);
	float weave = sin(UV.x * 520.0) * sin(UV.y * 520.0) * 0.018;
	float grain = fract(sin(dot(UV * vec2(143.1, 311.7), vec2(12.99, 78.23))) * 43758.55) - 0.5;
	base += vec3(weave + grain * 0.02);
	COLOR = vec4(base, 1.0);
}
