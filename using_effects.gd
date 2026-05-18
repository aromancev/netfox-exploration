extends Weapon

enum _Stage {
	NONE,
	LIGHT,
	HEAVY,
	RECOVER,
}

const _LIGHT_DURATION: float = 0.3
const _HEAVY_CHARGE_DURATION: float = 0.8
const _RECOVER_DURATION: float = 0.8

var _attack_stage_started_at: int = -1
var _attack_stage: int = _Stage.NONE

@export var input: UnitInput
@export var actor: Actor
@export var synchronizer: RollbackSynchronizer
@export var projectile_root: Node
@export var vfx_root: Node
@export var light_projectile: PackedScene
@export var heavy_projectile: PackedScene
@export var heavy_charge_vfx: PackedScene


func _get_rollback_states() -> PackedStringArray:
	return ["_attack_stage_started_at", "_attack_stage"]


func _rollback_tick(_delta: float, tick: int, _is_fresh: bool) -> void:
	if synchronizer.is_predicting():
		return

	var is_heavy: bool = input.is_action_long_pressed("action_primary")
	var is_light: bool = not is_heavy and input.is_action_just_pressed("action_primary")

	if is_light and _attack_stage == _Stage.NONE:
		_attack_stage_started_at = tick
		_attack_stage = _Stage.LIGHT
		_record_light_attack_effect()
		return

	if (
		_attack_stage == _Stage.LIGHT
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _LIGHT_DURATION
	):
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		_record_recover_effect()
		return

	if is_heavy and _attack_stage == _Stage.NONE:
		_attack_stage_started_at = tick
		_attack_stage = _Stage.HEAVY
		_record_heavy_hold_effect()
		return

	if _attack_stage == _Stage.HEAVY and not is_heavy:
		var heavy_charge_elapsed: float = NetworkTime.seconds_between(
			_attack_stage_started_at, tick
		)
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		if heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION:
			_record_heavy_release_effect()
		else:
			_record_recover_effect()
		return

	if (
		_attack_stage == _Stage.RECOVER
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _RECOVER_DURATION
	):
		_attack_stage_started_at = -1
		_attack_stage = _Stage.NONE


func _record_light_attack_effect() -> void:
	var direction: Vector3 = _get_projectile_direction()
	RollbackEffects.record(
		[self, &"light_projectile", _get_direction_key(direction)],
		func(ctx: RollbackEffects.Context) -> void:
			actor.play_animation(&"attack")
			var projectile: Node = _spawn_projectile(light_projectile, direction)
			ctx.on_revert = func() -> void:
				actor.play_animation(&"idle")
				if is_instance_valid(projectile):
					projectile.queue_free()
	)


func _record_heavy_hold_effect() -> void:
	RollbackEffects.record(
		[self, &"heavy_hold"],
		func(ctx: RollbackEffects.Context) -> void:
			actor.play_animation(&"attack_hold")
			var charge_vfx: Node = _spawn_charge_vfx()
			ctx.on_revert = func() -> void:
				actor.play_animation(&"idle")
				if is_instance_valid(charge_vfx):
					charge_vfx.queue_free()
	)


func _record_heavy_release_effect() -> void:
	var direction: Vector3 = _get_projectile_direction()
	RollbackEffects.record(
		[self, &"heavy_projectile", _get_direction_key(direction)],
		func(ctx: RollbackEffects.Context) -> void:
			actor.play_animation(&"attack_release")
			var projectile: Node = _spawn_projectile(heavy_projectile, direction)
			ctx.on_revert = func() -> void:
				actor.play_animation(&"idle")
				if is_instance_valid(projectile):
					projectile.queue_free()
	)


func _record_recover_effect() -> void:
	RollbackEffects.record(
		[self, &"recover"],
		func(_ctx: RollbackEffects.Context) -> void: actor.play_animation(&"idle")
	)


func _spawn_projectile(projectile_scene: PackedScene, direction: Vector3) -> Node:
	var projectile: Node = projectile_scene.instantiate()
	projectile_root.add_child(projectile)
	projectile.global_transform = _get_projectile_transform(direction)
	return projectile


func _spawn_charge_vfx() -> Node:
	var vfx: Node = heavy_charge_vfx.instantiate()
	vfx_root.add_child(vfx)
	vfx.global_transform = actor.muzzle.global_transform
	return vfx


func _get_projectile_direction() -> Vector3:
	var direction: Vector3 = input.get_aim().normalized()
	if direction.is_zero_approx():
		return -actor.muzzle.global_basis.z.normalized()

	return direction


func _get_direction_key(direction: Vector3) -> Vector3:
	return direction.snapped(Vector3(0.01, 0.01, 0.01))


func _get_projectile_transform(direction: Vector3) -> Transform3D:
	var projectile_transform: Transform3D = actor.muzzle.global_transform
	var safe_direction: Vector3 = direction
	if safe_direction.is_zero_approx():
		safe_direction = -projectile_transform.basis.z.normalized()

	return projectile_transform.looking_at(
		projectile_transform.origin + safe_direction, actor.global_basis.y
	)
