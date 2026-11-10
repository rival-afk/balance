extends RigidBody2D

## Платформа скользит по невидимому горизонтальному рельсу rail_y.
## Высота и вертикальная скорость принудительно равны rail_y,
## по горизонтали — полная динамика (тяга/демпфер/импульс маятника).
@export var rail_y := 270.0

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	var t := state.transform
	t.origin.y = rail_y
	state.transform = t
	var v := state.linear_velocity
	v.y = 0.0
	state.linear_velocity = v
