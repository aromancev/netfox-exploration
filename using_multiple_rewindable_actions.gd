extends Weapon

enum _Stage {
	NONE,
	LIGHT,
	HEAVY,
	RECOVER,
}

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

	var is_heavy := input.is_action_long_pressed("action_primary")
	var is_light := not is_heavy and input.is_action_just_pressed("action_primary")

	_action_light.set_active(is_light and _attack_stage == _Stage.NONE)
	match _action_light.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.LIGHT
			_action_light.set_context(_spawn_projectile(light_projectile))
		RewindableAction.ACTIVE:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.LIGHT
		RewindableAction.CANCELLING:
			_cancel_projectile(_action_light)

	_action_heavy_hold.set_active(is_heavy and _attack_stage == _Stage.NONE)
	match _action_heavy_hold.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.HEAVY
			_action_heavy_hold.set_context(_spawn_charge_vfx())
		RewindableAction.ACTIVE:
			_attack_stage_started_at = tick
			_attack_stage = _Stage.HEAVY
		RewindableAction.CANCELLING:
			_cancel_heavy_charge(_action_heavy_hold)

	if _attack_stage == _Stage.LIGHT and _action_light.has_confirmed():
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER

	var is_heavy_release := _attack_stage == _Stage.HEAVY and not is_heavy
	_action_heavy_release.set_active(is_heavy_release)
	match _action_heavy_release.get_status():
		RewindableAction.CONFIRMING:
			_attack_stage = _Stage.RECOVER
			_attack_stage_started_at = tick
			_cancel_heavy_charge(_action_heavy_hold)
			_action_heavy_release.set_context(_spawn_projectile(heavy_projectile))
		RewindableAction.ACTIVE:
			_attack_stage = _Stage.RECOVER
			_attack_stage_started_at = tick
		RewindableAction.CANCELLING:
			_cancel_projectile(_action_heavy_release)

	if _attack_stage == _Stage.RECOVER:
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


func _spawn_projectile(projectile_scene: PackedScene) -> Node:
	var projectile: Node = projectile_scene.instantiate()
	projectile_root.add_child(projectile)
	projectile.global_transform = actor.muzzle.global_transform
	return projectile


func _spawn_charge_vfx() -> Node:
	var vfx: Node = heavy_charge_vfx.instantiate()
	vfx_root.add_child(vfx)
	vfx.global_transform = actor.muzzle.global_transform
	return vfx


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
