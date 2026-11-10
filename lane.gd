extends Node2D

## Одна игра в составе роя. Физика маятника — на GPU (gpu_pendulum.gd).
## Менеджер (game.gd) шагает GPU и читает состояния; здесь только платформа и очки.

const ACCEL := 900.0
const RATE := 12.0           ## очков/сек при идеальной вертикали
const PERFECT_VERT := 0.90
const DANGER_VERT := 0.35
const ARM_LEVER := 60.0      ## плечо первой секции
const ARM2_OFFSET := 120.0   ## tip1 → base arm2

## Уровни помощи удержанию (пружина к вертикали на GPU).
const ASSIST_KP := [0.0, 3.0, 15.0, 60.0, 200.0]    ## Н·м/рад (g нормировано как 9.81)
const ASSIST_KD := [0.0, 1.2, 6.0, 25.0, 80.0]      ## демпфирование, Н·м·с
const ASSIST_NAMES := ["Нет", "Лёгкий", "Средний", "Сильный", "Максимум"]

@export var lane_id := 0
@export var assist_level := 1   ## 0 — без помощи, 1..4 — уровни облегчения

var manager = null           ## BalanceGame (game.gd)
var api_direction := 0.0     ## -1 = влево, 0 = стоп, +1 = вправо (от API)
var lane_idx := 0            ## индекс в GPU-пуле (присваивает менеджер)

var score := 0.0
var multiplier := 1.0
var perfect_streak := 0.0
var balance_time := 0.0
var verticality := 1.0
var tilt_total := 0.0
var tilt_rate := 0.0
var total_perfect := 0.0
var fault_count := 0
var fault_time := 0.0
var _prev_fault := false
var _prev_tilt := 0.0
var _prev_vx := 0.0
var _accel_x := 0.0

var _plane: RigidBody2D
var _arm1: Node2D
var _arm2: Node2D
var _sprite: Sprite2D
var _gpu_state: Vector4 = Vector4(PI, PI, 0.0, 0.0)

func _ready() -> void:
	_plane = $Rail/Plane
	_arm1 = $Rail/SpawnPivot/Arm1
	_arm2 = $Rail/SpawnPivot/Arm2
	_sprite = $Rail/Plane/Sprite
	$Rail/Plane/Cam.make_current()
	# исходная поза: стойка с маленьким случайным отклонением
	var rng := RandomNumberGenerator.new()
	var t1 := rng.randf_range(-0.10, 0.10)
	var t2 := rng.randf_range(-0.20, 0.20)
	var r1 := PI + t1
	var r2 := PI + t2
	if manager != null and manager._gpu != null:
		manager._gpu.init_lane(lane_idx, r1, r2, 0.0, 0.0)
	_update_arms(Vector4(r1, r2, 0.0, 0.0))

func set_assist(level: int) -> void:
	assist_level = clampi(level, 0, 4)

func set_api_direction(v: float) -> void:
	api_direction = clampf(v, -1.0, 1.0)

func assist_params() -> Vector2:
	var lvl := clampi(assist_level, 0, 4)
	return Vector2(ASSIST_KP[lvl], ASSIST_KD[lvl])

func _physics_process(delta: float) -> void:
	# управление: API важнее клавиатуры; клавиатура — только первая игра
	var direction := api_direction
	if direction == 0.0 and lane_id == 0:
		direction = Input.get_axis("ui_left", "ui_right")
	_plane.apply_central_force(Vector2(direction * ACCEL * _plane.mass, 0.0))

	# производная скорости платформы → ускорение (для маятника)
	var vx: float = _plane.linear_velocity.x
	if delta > 0.0:
		_accel_x = clampf((vx - _prev_vx) / delta / 60.0, -30.0, 30.0)
	_prev_vx = vx

	if manager != null and manager._gpu != null:
		var kp_kd := assist_params()
		manager._gpu.set_pivot(lane_idx, _accel_x, kp_kd.x, kp_kd.y)
		_gpu_state = manager._gpu.lane_state(lane_idx)
	else:
		# fallback: маятник не интегрируется — стоит вертикально
		_gpu_state = Vector4(PI, PI, 0.0, 0.0)
	_update_arms(_gpu_state)

	var t1 := _gpu_state.x
	var t2 := _gpu_state.y
	var h1 := -cos(t1)
	var h2 := -cos(t2)
	var up_avg := (h1 + h2) / 2.0
	verticality = clampf(up_avg, 0.0, 1.0)
	tilt_total = acos(clampf(up_avg, -1.0, 1.0))
	tilt_rate = lerp(tilt_rate, (tilt_total - _prev_tilt) / maxf(delta, 1e-6), 0.2)
	_prev_tilt = tilt_total

	var perfect := verticality > PERFECT_VERT
	var fault := up_avg > -0.2 and verticality < DANGER_VERT

	balance_time += delta
	if perfect:
		perfect_streak += delta
		total_perfect += delta
	else:
		perfect_streak = 0.0
	multiplier = 1.0 + minf(perfect_streak * 0.2, 4.0)
	score += verticality * verticality * RATE * multiplier * delta

	if fault:
		fault_time += delta
		if not _prev_fault:
			fault_count += 1
	_prev_fault = fault

	_sprite.material.set_shader_parameter("stress", clampf(1.0 - clampf(up_avg * 0.5 + 0.5, 0.0, 1.0), 0.0, 1.0))

func _update_arms(state: Vector4) -> void:
	var t1 := state.x
	var t2 := state.y
	var d1 := Vector2(-sin(t1), cos(t1))
	var d2 := Vector2(-sin(t2), cos(t2))
	var tip := d1 * (ARM_LEVER + ARM2_OFFSET)
	_arm1.position = d1 * ARM_LEVER
	_arm1.rotation = t1
	_arm2.position = d1 * ARM_LEVER + d1 * ARM2_OFFSET + d2 * ARM_LEVER
	_arm2.rotation = t2

func get_state() -> Dictionary:
	return {
		"lane": lane_id,
		"verticality": verticality,
		"tilt_deg": rad_to_deg(tilt_total),
		"tilt_rate_deg_s": rad_to_deg(tilt_rate),
		"lateral_velocity_px_s": _plane.linear_velocity.x,
		"score": score,
		"multiplier": multiplier,
		"perfect_streak_s": perfect_streak,
		"total_perfect_s": total_perfect,
		"balance_time_s": balance_time,
		"faults": fault_count,
		"fault_time_s": fault_time,
		"platform_x": _plane.global_position.x,
		"arm1_deg": rad_to_deg(_gpu_state.x),
		"arm2_deg": rad_to_deg(_gpu_state.y),
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
