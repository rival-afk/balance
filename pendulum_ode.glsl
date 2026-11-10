#[compute]
#version 450

layout(local_size_x = 64) in;

// состояние одним вектором на игру: (theta1, theta2, omega1, omega2)
layout(set = 0, binding = 0, std430) restrict buffer States {
	vec4 state[];
} states;

// на игру: (pivot_accel_x, unused, assist_kp, assist_kd)
layout(set = 0, binding = 1, std430) restrict buffer Pivots {
	vec4 pivot[];
} pivots;

// (dt, gravity, damping, count) — float(uint(count))
layout(set = 0, binding = 2, std430) restrict buffer Params {
	vec4 params;
} params;

vec4 step_pendulum(vec4 s, vec4 pv, float dt, float g, float damp) {
	float t1 = s.x, t2 = s.y, w1 = s.z, w2 = s.w;
	float pa = pv.x;
	float kp = pv.z, kd = pv.w;

	for (int i = 0; i < 4; i++) {
		float d = t1 - t2;
		float sind = sin(d), cosd = cos(d);
		float den = 2.0 - cosd * cosd;
		float a1 = (-3.0 * g * sin(t1) - g * sin(t1 - 2.0 * t2) - 2.0 * sind * (w2 * w2 + w1 * w1 * cosd)) / den;
		float a2 = (sind * (2.0 * w1 * w1 + 2.0 * g * cos(t1) + w2 * w2 * cosd)) / den;
		a1 -= pa * cos(t1);
		a2 -= pa * cos(t2);
		if (kp != 0.0 || kd != 0.0) {
			a1 += kp * sin(t1) - kd * w1;
			a2 += kp * sin(t2) - kd * w2;
		}
		w1 += a1 * dt;
		w2 += a2 * dt;
		w1 *= 1.0 - damp * dt;
		w2 *= 1.0 - damp * dt;
		t1 += w1 * dt;
		t2 += w2 * dt;
	}
	return vec4(t1, t2, w1, w2);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (float(i) >= params.params.w) return;
	states.state[i] = step_pendulum(states.state[i], pivots.pivot[i], params.params.x, params.params.y, params.params.z);
}
