shader_type canvas_item;

// Уровневая шкала: тёмный трек, латунная заливка слева,
// белый маркер текущего значения, засечки каждые 10%,
// зелёная риска на пороге идеала.
// uniform verticality: 0..1 — насколько маятник вертикален.
uniform float verticality : hint_range(0.0, 1.0) = 0.0;
uniform float perfect : hint_range(0.0, 1.0) = 0.9;

void fragment() {
	vec2 p = UV;
	vec4 col_out;
	vec4 ink = vec4(0.925, 0.925, 0.94, 1.0);
	vec3 track = vec3(0.125, 0.128, 0.148);
	vec3 brass = vec3(0.910, 0.765, 0.227);
	vec3 brass_dim = vec3(0.42, 0.352, 0.112);
	vec3 ok = vec3(0.36, 0.78, 0.50);
	if (p.x < 0.02 || p.x > 0.98 || p.y < 0.12 || p.y > 0.88) {
		col_out = vec4(0.10, 0.10, 0.12, 1.0);
	} else {
		float x = clamp((p.x - 0.02) / 0.96, 0.0, 1.0);
		vec3 col = track;
		float filled = step(x, verticality);
		float ticks = step(0.55, fract(x * 10.0));
		col = mix(col, brass_dim, filled * 0.35);
		col = mix(col, brass, filled);
		col *= mix(1.0, 0.82, ticks);
		// риска порога идеала
		float perfect_tick = smoothstep(0.004, 0.0, abs(x - perfect));
		col = mix(col, ok, perfect_tick * 0.9);
		// белый маркер текущего значения
		float marker = smoothstep(0.008, 0.0, abs(x - verticality));
		col = mix(col, ink.rgb, marker);
		col_out = vec4(col, 1.0);
	}
	COLOR = col_out;
}
