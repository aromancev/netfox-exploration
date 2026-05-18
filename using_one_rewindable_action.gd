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

const _EVENT_LIGHT := &"light"
const _EVENT_HEAVY_HOLD := &"heavy_hold"
const _EVENT_HEAVY_RELEASE := &"heavy_release"
const _EVENT_RECOVER := &"recover"

var _attack_stage_started_at: int = -1
var _attack_stage: int = _Stage.NONE
var _heavy_projectile_spawned: bool = false

# This is necessary because we're only using one RA. I don't think this is how it should be.
var _last_confirmed_event: StringName
var _last_cancelled_event: StringName

@export var input: UnitInput
@export var actor: Actor
@export var synchronizer: RollbackSynchronizer
@export var projectile_root: Node
@export var vfx_root: Node
@export var light_projectile: PackedScene
@export var heavy_projectile: PackedScene
@export var heavy_charge_vfx: PackedScene

@onready var _action: RewindableAction = $Action


func _ready() -> void:
	NetworkTime.after_tick_loop.connect(_after_loop)
	_action.mutate(self)


func _get_rollback_states() -> PackedStringArray:
	return ["_attack_stage_started_at", "_attack_stage", "_heavy_projectile_spawned"]


func _rollback_tick(_delta: float, tick: int, _is_fresh: bool) -> void:
	if synchronizer.is_predicting():
		return

	var is_heavy: bool = input.is_action_long_pressed("action_primary")
	var is_light: bool = not is_heavy and input.is_action_just_pressed("action_primary")
	var starts_light: bool = is_light and _attack_stage == _Stage.NONE
	var starts_heavy: bool = is_heavy and _attack_stage == _Stage.NONE
	var heavy_charge_elapsed: float = NetworkTime.seconds_between(_attack_stage_started_at, tick)
	var releases_heavy: bool = (
		_attack_stage == _Stage.HEAVY
		and not is_heavy
		and not _heavy_projectile_spawned
		and heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION
	)
	var cancels_heavy: bool = (
		_attack_stage == _Stage.HEAVY
		and not is_heavy
		and not _heavy_projectile_spawned
		and heavy_charge_elapsed < _HEAVY_CHARGE_DURATION
	)

	var should_be_active: bool = starts_light or starts_heavy or _attack_stage != _Stage.NONE
	_action.set_active(should_be_active)

	match _action.get_status():
		RewindableAction.CONFIRMING:
			if starts_light:
				_start_light_attack(tick)
			elif starts_heavy:
				_start_heavy_attack(tick)
		RewindableAction.CANCELLING:
			_cancel_attack()

	if (
		_attack_stage == _Stage.LIGHT
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _LIGHT_DURATION
	):
		_start_recover(tick)
		return

	if releases_heavy:
		_release_heavy_attack(tick)
		return

	if cancels_heavy:
		_cancel_heavy_attack(tick)
		return

	if (
		_attack_stage == _Stage.RECOVER
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _RECOVER_DURATION
	):
		_attack_stage_started_at = -1
		_attack_stage = _Stage.NONE
		_heavy_projectile_spawned = false
		_action.set_active(false)


func _after_loop() -> void:
	if _last_cancelled_event != &"":
		actor.play_animation(&"idle")
		_last_cancelled_event = &""
		return

	if _last_confirmed_event == _EVENT_LIGHT:
		actor.play_animation(&"attack")
	elif _last_confirmed_event == _EVENT_HEAVY_RELEASE:
		actor.play_animation(&"attack_release")
	elif _last_confirmed_event == _EVENT_HEAVY_HOLD:
		actor.play_animation(&"attack_hold")
	elif _last_confirmed_event == _EVENT_RECOVER:
		actor.play_animation(&"idle")

	_last_confirmed_event = &""


func _start_light_attack(tick: int) -> void:
	_last_confirmed_event = _EVENT_LIGHT
	_attack_stage_started_at = tick
	_attack_stage = _Stage.LIGHT
	var context: Dictionary = {
		"kind": _EVENT_LIGHT,
		"projectile": _spawn_projectile(light_projectile, _get_projectile_direction()),
	}
	_action.set_context(context)


func _start_heavy_attack(tick: int) -> void:
	_last_confirmed_event = _EVENT_HEAVY_HOLD
	_attack_stage_started_at = tick
	_attack_stage = _Stage.HEAVY
	_heavy_projectile_spawned = false
	var context: Dictionary = {
		"kind": _EVENT_HEAVY_HOLD,
		"vfx": _spawn_charge_vfx(),
	}
	_action.set_context(context)


func _release_heavy_attack(tick: int) -> void:
	_last_confirmed_event = _EVENT_HEAVY_RELEASE
	_attack_stage_started_at = tick
	_attack_stage = _Stage.RECOVER
	_heavy_projectile_spawned = true

	var context: Dictionary = _get_action_context()
	var charge_vfx: Variant = context.get("vfx")
	if charge_vfx is Node:
		(charge_vfx as Node).queue_free()

	context.erase("vfx")
	context["kind"] = _EVENT_HEAVY_RELEASE
	context["projectile"] = _spawn_projectile(heavy_projectile, _get_projectile_direction())
	_action.set_context(context)


func _start_recover(tick: int) -> void:
	_last_confirmed_event = _EVENT_RECOVER
	_attack_stage_started_at = tick
	_attack_stage = _Stage.RECOVER


func _cancel_heavy_attack(tick: int) -> void:
	var context: Dictionary = _get_action_context()
	var charge_vfx: Variant = context.get("vfx")
	if charge_vfx is Node:
		(charge_vfx as Node).queue_free()

	context.erase("vfx")
	context["kind"] = _EVENT_RECOVER
	_action.set_context(context)
	_start_recover(tick)


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
	return input.get_aim().normalized()


func _get_projectile_transform(direction: Vector3) -> Transform3D:
	var projectile_transform: Transform3D = actor.muzzle.global_transform
	return projectile_transform.looking_at(
		projectile_transform.origin + direction, actor.global_basis.y
	)


func _cancel_attack() -> void:
	var context: Dictionary = _get_action_context()
	var kind: Variant = context.get("kind")
	if kind is StringName:
		_last_cancelled_event = kind

	var projectile: Variant = context.get("projectile")
	if projectile is Node:
		(projectile as Node).queue_free()

	var vfx: Variant = context.get("vfx")
	if vfx is Node:
		(vfx as Node).queue_free()

	_heavy_projectile_spawned = false
	_action.erase_context()


func _get_action_context() -> Dictionary:
	if not _action.has_context():
		return {}

	var context: Variant = _action.get_context()
	if context is Dictionary:
		return context

	return {}
