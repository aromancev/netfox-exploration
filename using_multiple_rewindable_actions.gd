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

@onready var _action_light: RewindableAction = $Light
@onready var _action_heavy_hold: RewindableAction = $HeavyHold
@onready var _action_heavy_release: RewindableAction = $HeavyRelease


func _ready() -> void:
	NetworkTime.after_tick_loop.connect(_after_loop)
	_action_light.mutate(self)
	_action_heavy_hold.mutate(self)
	_action_heavy_release.mutate(self)


func _get_rollback_states() -> PackedStringArray:
	return ["_attack_stage_started_at", "_attack_stage"]


func _rollback_tick(_delta: float, tick: int, _is_fresh: bool) -> void:
	if synchronizer.is_predicting():
		return

	var is_heavy: bool = input.is_action_long_pressed("action_primary")
	var is_light: bool = not is_heavy and input.is_action_just_pressed("action_primary")
	var heavy_charge_elapsed: float = NetworkTime.seconds_between(_attack_stage_started_at, tick)

	_action_light.set_active(is_light and _attack_stage == _Stage.NONE)
	match _action_light.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.LIGHT
			_action_light.set_context(
				_spawn_projectile(light_projectile, _get_projectile_direction())
			)
		RewindableAction.ACTIVE:
			pass
		RewindableAction.CANCELLING:
			_cancel_projectile(_action_light)

	_action_heavy_hold.set_active(is_heavy and _attack_stage == _Stage.NONE)
	match _action_heavy_hold.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.HEAVY
			_action_heavy_hold.set_context(_spawn_charge_vfx())
		RewindableAction.ACTIVE:
			pass
		RewindableAction.CANCELLING:
			_cancel_heavy_charge(_action_heavy_hold)

	if (
		_attack_stage == _Stage.LIGHT
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _LIGHT_DURATION
	):
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER

	var is_heavy_release: bool = (
		_attack_stage == _Stage.HEAVY
		and not is_heavy
		and heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION
	)
	_action_heavy_release.set_active(is_heavy_release)
	match _action_heavy_release.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage = _Stage.RECOVER
			_attack_stage_started_at = tick
			_cancel_heavy_charge(_action_heavy_hold)
			_action_heavy_release.set_context(
				_spawn_projectile(heavy_projectile, _get_projectile_direction())
			)
		RewindableAction.ACTIVE:
			pass
		RewindableAction.CANCELLING:
			_cancel_projectile(_action_heavy_release)

	if (
		_attack_stage == _Stage.HEAVY
		and not is_heavy
		and heavy_charge_elapsed < _HEAVY_CHARGE_DURATION
	):
		_cancel_heavy_charge(_action_heavy_hold)
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER

	if (
		_attack_stage == _Stage.RECOVER
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _RECOVER_DURATION
	):
		_attack_stage_started_at = -1
		_attack_stage = _Stage.NONE


func _after_loop() -> void:
	if _action_light.has_cancelled() or _action_heavy_release.has_cancelled():
		actor.play_animation(&"idle")
	elif _action_light.has_confirmed():
		actor.play_animation(&"attack")
	elif _action_heavy_release.has_confirmed():
		actor.play_animation(&"attack_release")
	elif _action_heavy_hold.has_confirmed():
		actor.play_animation(&"attack_hold")


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
	var direction: Vector3 = -actor.global_basis.z.normalized()
	if direction.is_zero_approx():
		return -actor.muzzle.global_basis.z.normalized()

	return direction


func _get_projectile_transform(direction: Vector3) -> Transform3D:
	var projectile_transform: Transform3D = actor.muzzle.global_transform
	var safe_direction: Vector3 = direction
	if safe_direction.is_zero_approx():
		safe_direction = -projectile_transform.basis.z.normalized()

	return projectile_transform.looking_at(
		projectile_transform.origin + safe_direction, actor.global_basis.y
	)


func _cancel_projectile(action: RewindableAction) -> void:
	if not action.has_context():
		return

	var projectile: Variant = action.get_context()
	if projectile is Node:
		(projectile as Node).queue_free()

	action.erase_context()


func _cancel_heavy_charge(action: RewindableAction) -> void:
	if not action.has_context():
		return

	var charge_vfx: Variant = action.get_context()
	if charge_vfx is Node:
		(charge_vfx as Node).queue_free()

	action.erase_context()
