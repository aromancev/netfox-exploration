extends Weapon

enum _Stage {
	NONE,
	LIGHT,
	HEAVY,
	RECOVER,
}

const _EVENT_LIGHT := &"light"
const _EVENT_HEAVY_HOLD := &"heavy_hold"
const _EVENT_HEAVY_RELEASE := &"heavy_release"

var _attack_stage_started_at: int = -1
var _attack_stage: int = _Stage.NONE
var _heavy_projectile_spawned: bool = false

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

	var is_heavy := input.is_action_long_pressed("action_primary")
	var is_light := not is_heavy and input.is_action_just_pressed("action_primary")
	var starts_light := is_light and _attack_stage == _Stage.NONE
	var starts_heavy := is_heavy and _attack_stage == _Stage.NONE
	var releases_heavy := _attack_stage == _Stage.HEAVY and not is_heavy and not _heavy_projectile_spawned

	var should_be_active := starts_light or starts_heavy or _attack_stage != _Stage.NONE
	_action.set_active(should_be_active)

	match _action.get_status():
		RewindableAction.CONFIRMING:
			if starts_light:
				_start_light_attack(tick)
			elif starts_heavy:
				_start_heavy_attack(tick)
		RewindableAction.CANCELLING:
			_cancel_attack()

	if releases_heavy:
		_release_heavy_attack(tick)

	if _attack_stage == _Stage.LIGHT:
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
	elif _attack_stage == _Stage.RECOVER:
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

	_last_confirmed_event = &""


func _start_light_attack(tick: int) -> void:
	_last_confirmed_event = _EVENT_LIGHT
	_attack_stage_started_at = tick
	_attack_stage = _Stage.LIGHT
	_action.set_context({
		"kind": _EVENT_LIGHT,
		"projectile": _spawn_projectile(light_projectile),
	})


func _start_heavy_attack(tick: int) -> void:
	_last_confirmed_event = _EVENT_HEAVY_HOLD
	_attack_stage_started_at = tick
	_attack_stage = _Stage.HEAVY
	_heavy_projectile_spawned = false
	_action.set_context({
		"kind": _EVENT_HEAVY_HOLD,
		"vfx": _spawn_charge_vfx(),
	})


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
	context["projectile"] = _spawn_projectile(heavy_projectile)
	_action.set_context(context)


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
