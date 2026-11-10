extends RefCounted

## GPU-интегрирование двухзвенного маятника для всех лейнов одним dispatch'ем.
## Если GPU/compute недоступны (headless), cpu_step() повторяет то же самое на CPU.

const MAX_LANES := 256
const SUBSTEPS := 4

var available := false
var _rd: RenderingDevice
var _pipeline: RID
var _state_buf: RID
var _pivot_buf: RID
var _params_buf: RID
var _uniform_set: RID
var _states := PackedFloat32Array()
var _pivots := PackedFloat32Array()

func init(initial_lanes: int) -> bool:
	_states.resize(4 * MAX_LANES)
	_pivots.resize(4 * MAX_LANES)
	for i in MAX_LANES:
		_states[4 * i + 0] = PI
		_states[4 * i + 1] = PI
		_states[4 * i + 2] = 0.0
		_states[4 * i + 3] = 0.0
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return false
	var shader_file: Resource = load("res://pendulum_ode.glsl")
	var spiral: RDShaderSPIRV = shader_file.get_spirv() if shader_file else null
	if spiral == null:
		return false
	var shader: RID = _rd.shader_create_from_spirv(spiral)
	if shader == RID():
		return false
	_pipeline = _rd.compute_pipeline_create(shader)

	_state_buf = _rd.storage_buffer_create(MAX_LANES * 16, _states.to_byte_array())
	var pivot_bytes := _pivots.to_byte_array()
	_pivot_buf = _rd.storage_buffer_create(MAX_LANES * 16, pivot_bytes)
	var params := PackedFloat32Array([1.0 / 60.0, 9.81, 0.10, float(MAX_LANES)])
	_params_buf = _rd.storage_buffer_create(16, params.to_byte_array())
	var uniforms := []
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(_state_buf)
	uniforms.append(u0)
	var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(_pivot_buf)
	uniforms.append(u1)
	var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(_params_buf)
	uniforms.append(u2)
	_uniform_set = _rd.uniform_set_create(uniforms, shader, 0)
	available = true
	set_lane_count(initial_lanes)
	return true

func set_lane_count(n: int) -> void:
	set_dt(1.0 / 60.0, n)

func set_dt(dt: float, n := -1) -> void:
	var cnt := (_states.size() / 4) if n < 0 else n
	var params := PackedFloat32Array([dt, 9.81, 0.10, float(cnt)])
	if _rd:
		_rd.buffer_update(_params_buf, 0, 16, params.to_byte_array())

func set_pivot(idx: int, pivot_accel: float, assist_kp: float, assist_kd: float) -> void:
	if idx < 0 or idx >= MAX_LANES:
		return
	var idx2 := idx * 4
	_pivots[idx2 + 0] = pivot_accel
	_pivots[idx2 + 1] = 0.0
	_pivots[idx2 + 2] = assist_kp
	_pivots[idx2 + 3] = assist_kd
	if _rd:
		var buf := PackedFloat32Array([pivot_accel, 0.0, assist_kp, assist_kd])
		_rd.buffer_update(_pivot_buf, idx2 * 4, 16, buf.to_byte_array())

func read_state(idx: int) -> Vector4:
	if not available:
		return Vector4(_states[4 * idx + 0], _states[4 * idx + 1], _states[4 * idx + 2], _states[4 * idx + 3])
	var bytes := _rd.buffer_get_data(_state_buf, idx * 16, 16)
	var f := bytes.to_float32_array()
	return Vector4(f[0], f[1], f[2], f[3])

func init_lane(idx: int, theta1: float, theta2: float, w1 := 0.0, w2 := 0.0) -> void:
	if idx < 0 or idx >= MAX_LANES:
		return
	_states[4 * idx + 0] = theta1
	_states[4 * idx + 1] = theta2
	_states[4 * idx + 2] = w1
	_states[4 * idx + 3] = w2
	if _rd:
		var buf := PackedFloat32Array([theta1, theta2, w1, w2])
		_rd.buffer_update(_state_buf, idx * 16, 16, buf.to_byte_array())

func step(dt: float) -> void:
	if not available:
		cpu_step(dt)
		return
	set_dt(dt, MAX_LANES)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
	var groups := int(ceil(float(MAX_LANES) / 64.0))
	_rd.compute_list_dispatch(list, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	var bytes := _rd.buffer_get_data(_state_buf)
	_states = bytes.to_float32_array()

func lane_state(idx: int) -> Vector4:
	if idx < 0 or idx >= MAX_LANES:
		return Vector4.ZERO
	return Vector4(_states[4 * idx + 0], _states[4 * idx + 1], _states[4 * idx + 2], _states[4 * idx + 3])

func cpu_step(dt: float) -> void:
	var g := 9.81
	var damp := 0.10
	var sub := dt / float(SUBSTEPS)
	for i in MAX_LANES:
		var t1 := _states[4*i+0]; var t2 := _states[4*i+1]; var w1 := _states[4*i+2]; var w2 := _states[4*i+3]
		var pa := _pivots[4*i+0]
		var kp := _pivots[4*i+2]; var kd := _pivots[4*i+3]
		for _s in SUBSTEPS:
			var d := t1 - t2
			var sind := sin(d); var cosd := cos(d)
			var den := 2.0 - cosd * cosd
			var a1 := (-3.0 * g * sin(t1) - g * sin(t1 - 2.0*t2) - 2.0 * sind * (w2*w2 + w1*w1*cosd)) / den
			var a2 := (sind * (2.0*w1*w1 + 2.0*g*cos(t1) + w2*w2*cosd)) / den
			a1 -= pa * cos(t1); a2 -= pa * cos(t2)
			if kp != 0.0 or kd != 0.0:
				a1 += kp * sin(t1) - kd * w1
				a2 += kp * sin(t2) - kd * w2
			w1 += a1 * sub; w2 += a2 * sub
			w1 *= 1.0 - damp * sub; w2 *= 1.0 - damp * sub
			t1 += w1 * sub; t2 += w2 * sub
		_states[4*i+0] = t1; _states[4*i+1] = t2; _states[4*i+2] = w1; _states[4*i+3] = w2

func free_device() -> void:
	if _rd == null:
		return
	_rd.free_rid(_uniform_set)
	_rd.free_rid(_pipeline)
	_rd.free_rid(_state_buf)
	_rd.free_rid(_pivot_buf)
	_rd.free_rid(_params_buf)
	_rd = null
	available = false
