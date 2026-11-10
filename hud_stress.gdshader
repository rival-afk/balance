shader_type canvas_item;

// Накал корпуса платформы пропорционален напряжению (1 - verticality).
// Текстура спрайта — встроенный TEXTURE, расчёт пикселей на GPU.
uniform float stress : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float pulse = 0.6 + 0.4 * sin(TIME * 9.0);
	vec3 heat = vec3(1.0, 0.32, 0.08) * stress * pulse;
	COLOR = vec4(c.rgb + heat * c.a, c.a);
}
