extends Node2D

## Одна игра в составе роя. Вся физика — аналитическая ODE (1:1 с Rust balance_env).
## Менеджер шагает ODE и выставляет позиционные узлы; здесь только платформа и очки.

## Физика в СИ: килограммы, метры, ньютоны. Рендер — PX_PER_M пикселей на метр.
const GRAVITY := 9.81
const M_CART := 12.0
const M1 := 1.0
const M2 := 1.0
const L1 := 1.0
const L2 := 1.0
const CART_DAMP := 3.0
## Максимальная сила привода, Н (~5 м/с² на 14 кг).
const CART_ACCEL_RAW := 70.0
## Ход тележки по рельсу в метрах (стенки нарисованы на ±360 px = ±3 м).
const CART_LIMIT := 2.2
const DAMPING := 0.10
## Масштаб: спрайт плеча 120 px = 1 м.
const PX_PER_M := 120.0
## Фиксированный шаг физики — ровно как в Rust/WGSL (не зависит от FPS и time_scale).
const FIXED_DT := 1.0 / 60.0
const RATE := 12.0
const PERFECT_VERT := 0.90
const DANGER_VERT := 0.35
const MULT_GAIN := 0.2
const MAX_MULT := 4.0

const ASSIST_KP := [0.0, 3.0, 15.0, 60.0, 200.0]
const ASSIST_KD := [0.0, 1.2, 6.0, 25.0, 80.0]
const ASSIST_NAMES := ["Нет", "Лёгкий", "Средний", "Сильный", "Максимум"]

@export var lane_id := 0
@export var assist_level := 0

var manager = null
var api_direction := 0.0
var lane_idx := 0

var score := 0.0
var multiplier := 1.0
var perfect_streak := 0.0
var total_perfect := 0.0
var balance_time := 0.0
var fault_count := 0
var fault_time := 0.0
var verticality := 1.0
var tilt_total := 0.0
var tilt_rate := 0.0
var prev_fault := false
var _prev_tilt := 0.0
var _accum := 0.0

# состояние: th1, th2, w1, w2, x, v
var th1 := 0.0
var th2 := 0.0
var w1 := 0.0
var w2 := 0.0
var x := 0.0
var v := 0.0

var _plane: Node2D
var _arm1: Node2D
var _arm2: Node2D
var _pivot: Node2D
var _sprite: Sprite2D

func _ready() -> void:
	_plane = $Rail/Plane
	_arm1 = $Rail/SpawnPivot/Arm1
	_arm2 = $Rail/SpawnPivot/Arm2
	_pivot = $Rail/SpawnPivot
	_sprite = $Rail/Plane/Sprite
	$Rail/Cam.make_current()
	var rng := RandomNumberGenerator.new()
	_set_state(PI + rng.randf_range(-0.05, 0.05), PI + rng.randf_range(-0.10, 0.10), 0.0, 0.0, 0.0, 0.0)

func _set_state(t1: float, t2: float, v1: float, v2: float, px: float, vx: float) -> void:
	th1 = t1; th2 = t2; w1 = v1; w2 = v2; x = px; v = vx
	_update_arms()

func set_assist(level: int) -> void:
	assist_level = clampi(level, 0, 4)

func set_api_direction(dir: float) -> void:
	api_direction = clampf(dir, -1.0, 1.0)

func assist_params() -> Vector2:
	var lvl := clampi(assist_level, 0, 4)
	return Vector2(ASSIST_KP[lvl], ASSIST_KD[lvl])

func _physics_process(delta: float) -> void:
	var direction := api_direction
	if direction == 0.0 and lane_id == 0:
		direction = Input.get_axis("ui_left", "ui_right")

	# Фиксированный шаг: одна и та же дискретизация, что в Rust и WGSL,
	# при любом FPS и любом Engine.time_scale.
	_accum += delta
	if _accum > 0.5:
		_accum = 0.5
	while _accum >= FIXED_DT - 1e-6:
		_step(FIXED_DT, direction * CART_ACCEL_RAW)
		_accum -= FIXED_DT

	_plane.position.x = x * PX_PER_M
	_pivot.position.x = x * PX_PER_M
	_update_arms()

	var up_avg := (-cos(th1) - cos(th2)) * 0.5
	_sprite.material.set_shader_parameter("stress", clampf(1.0 - clampf(up_avg * 0.5 + 0.5, 0.0, 1.0), 0.0, 1.0))

func _step(dt: float, force: float) -> void:
	var cur := [th1, th2, w1, w2, x, v]
	var k1 := _deriv(cur, force)
	var s2 := [cur[0] + 0.5 * dt * k1[0], cur[1] + 0.5 * dt * k1[1], cur[2] + 0.5 * dt * k1[2], cur[3] + 0.5 * dt * k1[3], cur[4] + 0.5 * dt * k1[4], cur[5] + 0.5 * dt * k1[5]]
	var k2 := _deriv(s2, force)
	var s3 := [cur[0] + 0.5 * dt * k2[0], cur[1] + 0.5 * dt * k2[1], cur[2] + 0.5 * dt * k2[2], cur[3] + 0.5 * dt * k2[3], cur[4] + 0.5 * dt * k2[4], cur[5] + 0.5 * dt * k2[5]]
	var k3 := _deriv(s3, force)
	var s4 := [cur[0] + dt * k3[0], cur[1] + dt * k3[1], cur[2] + dt * k3[2], cur[3] + dt * k3[3], cur[4] + dt * k3[4], cur[5] + dt * k3[5]]
	var k4 := _deriv(s4, force)
	th1 = cur[0] + dt * (k1[0] + 2.0*k2[0] + 2.0*k3[0] + k4[0]) / 6.0
	th2 = cur[1] + dt * (k1[1] + 2.0*k2[1] + 2.0*k3[1] + k4[1]) / 6.0
	w1  = cur[2] + dt * (k1[2] + 2.0*k2[2] + 2.0*k3[2] + k4[2]) / 6.0
	w2  = cur[3] + dt * (k1[3] + 2.0*k2[3] + 2.0*k3[3] + k4[3]) / 6.0
	x   = cur[4] + dt * (k1[4] + 2.0*k2[4] + 2.0*k3[4] + k4[4]) / 6.0
	v   = cur[5] + dt * (k1[5] + 2.0*k2[5] + 2.0*k3[5] + k4[5]) / 6.0

	if x > CART_LIMIT:
		x = CART_LIMIT
		if v > 0.0: v = 0.0
	elif x < -CART_LIMIT:
		x = -CART_LIMIT
		if v < 0.0: v = 0.0

	var up_avg := (-cos(th1) - cos(th2)) * 0.5
	verticality = clampf(up_avg, 0.0, 1.0)
	tilt_total = acos(clampf(up_avg, -1.0, 1.0))
	tilt_rate = lerp(tilt_rate, (tilt_total - _prev_tilt) / dt, 0.2)
	_prev_tilt = tilt_total

	var perfect := verticality > PERFECT_VERT
	var fault := up_avg > -0.2 and verticality < DANGER_VERT

	balance_time += dt
	if perfect:
		perfect_streak += dt
		total_perfect += dt
	else:
		perfect_streak = 0.0
	multiplier = 1.0 + minf(perfect_streak * MULT_GAIN, MAX_MULT)
	score += verticality * verticality * RATE * multiplier * dt

	if fault:
		fault_time += dt
		if not prev_fault:
			fault_count += 1
	prev_fault = fault

func _deriv(s: Array, force: float) -> Array:
	var t1 := float(s[0]); var t2 := float(s[1]); var v1 := float(s[2]); var v2 := float(s[3]); var vx := float(s[5])
	var d := t1 - t2
	var cd := cos(d); var sd := sin(d)
	var s1 := sin(t1); var s2 := sin(t2)
	var c1 := cos(t1); var c2 := cos(t2)

	# M(q) * a = b — тот же Лагранжиан, что в Rust и WGSL.
	var m00 := M_CART + M1 + M2
	var m01 := (M1 + M2) * L1 * c1
	var m02 := M2 * L2 * c2
	var m10 := m01
	var m11 := (M1 + M2) * L1 * L1
	var m12 := M2 * L1 * L2 * cd
	var m20 := m02
	var m21 := m12
	var m22 := M2 * L2 * L2

	var b0 := force - CART_DAMP * vx + (M1 + M2) * L1 * s1 * v1 * v1 + M2 * L2 * s2 * v2 * v2
	var b1 := -(M2 * L1 * L2 * sd * v2 * v2 + (M1 + M2) * GRAVITY * L1 * s1)
	var b2 := M2 * L1 * L2 * sd * v1 * v1 - M2 * GRAVITY * L2 * s2

	var det := m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)
	var ac := (b0 * (m11 * m22 - m12 * m21) - m01 * (b1 * m22 - m12 * b2) + m02 * (b1 * m21 - m11 * b2)) / det
	var a1 := (m00 * (b1 * m22 - m12 * b2) - b0 * (m10 * m22 - m12 * m20) + m02 * (m10 * b2 - b1 * m20)) / det
	var a2 := (m00 * (m11 * b2 - b1 * m21) - m01 * (m10 * b2 - b1 * m20) + b0 * (m10 * m21 - m11 * m20)) / det

	# angular damping on the arms
	a1 = a1 - DAMPING * v1
	a2 = a2 - DAMPING * v2

	var lvl := clampi(assist_level, 0, 4)
	var kp: float = ASSIST_KP[lvl]
	var kd: float = ASSIST_KD[lvl]
	a1 = a1 + kp * s1 - kd * v1
	a2 = a2 + kp * s2 - kd * v2

	return [v1, v2, a1, a2, vx, ac]

func _update_arms() -> void:
	var d1 := Vector2(-sin(th1), cos(th1))
	var d2 := Vector2(-sin(th2), cos(th2))
	_arm1.position = d1 * (L1 * PX_PER_M * 0.5)
	_arm1.rotation = th1
	var tip := d1 * (L1 * PX_PER_M)
	_arm2.position = tip + d2 * (L2 * PX_PER_M * 0.5)
	_arm2.rotation = th2

func get_state() -> Dictionary:
	return {
		"lane": lane_id,
		"verticality": verticality,
		"tilt_deg": rad_to_deg(tilt_total),
		"tilt_rate_deg_s": rad_to_deg(tilt_rate),
		"lateral_velocity_px_s": v * PX_PER_M,
		"score": score,
		"multiplier": multiplier,
		"perfect_streak_s": perfect_streak,
		"total_perfect_s": total_perfect,
		"balance_time_s": balance_time,
		"faults": fault_count,
		"fault_time_s": fault_time,
		"platform_x": x * PX_PER_M,
		"arm1_deg": rad_to_deg(th1),
		"arm2_deg": rad_to_deg(th2),
		"assist": clampi(assist_level, 0, 4),
		"assist_name": ASSIST_NAMES[clampi(assist_level, 0, 4)],
	}

func reset() -> void:
	score = 0.0
	multiplier = 1.0
	perfect_streak = 0.0
	total_perfect = 0.0
	balance_time = 0.0
	fault_count = 0
	fault_time = 0.0
	verticality = 1.0
	tilt_total = 0.0
	tilt_rate = 0.0
