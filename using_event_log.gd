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

const _EVENT_LIGHT_PROJECTILE: StringName = &"light_projectile"
const _EVENT_HEAVY_HOLD: StringName = &"heavy_hold"
const _EVENT_HEAVY_PROJECTILE: StringName = &"heavy_projectile"
const _EVENT_RECOVER: StringName = &"recover"

var _attack_stage_started_at: int = -1
var _attack_stage: int = _Stage.NONE

var _active_projectiles: Dictionary = {}
var _active_charge_vfx: Dictionary = {}

@export var input: UnitInput
@export var actor: Actor
@export var synchronizer: RollbackSynchronizer
@export var projectile_root: Node
@export var vfx_root: Node
@export var light_projectile: PackedScene
@export var heavy_projectile: PackedScene
@export var heavy_charge_vfx: PackedScene

@onready var _event_stream: RollbackEventStream = RollbackEventLog.get_stream(_get_stream_id())


func _ready() -> void:
	_event_stream.event_applied.connect(_on_event_applied)
	_event_stream.event_reverted.connect(_on_event_reverted)


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
		_append_projectile_event(_EVENT_LIGHT_PROJECTILE)
		return

	if (
		_attack_stage == _Stage.LIGHT
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _LIGHT_DURATION
	):
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		_append_event(_EVENT_RECOVER)
		return

	if is_heavy and _attack_stage == _Stage.NONE:
		_attack_stage_started_at = tick
		_attack_stage = _Stage.HEAVY
		_append_event(_EVENT_HEAVY_HOLD)
		return

	if _attack_stage == _Stage.HEAVY and not is_heavy:
		var heavy_charge_elapsed: float = NetworkTime.seconds_between(
			_attack_stage_started_at, tick
		)
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		if heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION:
			_append_projectile_event(_EVENT_HEAVY_PROJECTILE)
		else:
			_append_event(_EVENT_RECOVER)
		return

	if (
		_attack_stage == _Stage.RECOVER
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _RECOVER_DURATION
	):
		_attack_stage_started_at = -1
		_attack_stage = _Stage.NONE


func _append_projectile_event(kind: StringName) -> void:
	var event: RollbackEvent = RollbackEvent.new()
	event.payload = var_to_bytes(
		{
			"kind": kind,
			"direction": _get_projectile_direction(),
		}
	)
	_event_stream.append_event(event)


func _append_event(kind: StringName) -> void:
	var event: RollbackEvent = RollbackEvent.new()
	event.payload = var_to_bytes({"kind": kind})
	_event_stream.append_event(event)


func _on_event_applied(event: RollbackEvent) -> void:
	var payload: Dictionary = _decode_payload(event.payload)
	var kind: Variant = payload.get("kind")
	if kind == _EVENT_LIGHT_PROJECTILE:
		actor.play_animation(&"attack")
		var light_direction: Vector3 = _get_payload_direction(payload)
		var light_projectile_node: Node = _spawn_projectile(light_projectile, light_direction)
		_active_projectiles[_payload_key(event.payload)] = light_projectile_node
	elif kind == _EVENT_HEAVY_HOLD:
		actor.play_animation(&"attack_hold")
		_active_charge_vfx[_payload_key(event.payload)] = _spawn_charge_vfx()
	elif kind == _EVENT_HEAVY_PROJECTILE:
		_free_charge_vfx_for_kind(_EVENT_HEAVY_HOLD)
		actor.play_animation(&"attack_release")
		var heavy_direction: Vector3 = _get_payload_direction(payload)
		var heavy_projectile_node: Node = _spawn_projectile(heavy_projectile, heavy_direction)
		_active_projectiles[_payload_key(event.payload)] = heavy_projectile_node
	elif kind == _EVENT_RECOVER:
		_free_charge_vfx_for_kind(_EVENT_HEAVY_HOLD)
		actor.play_animation(&"idle")


func _on_event_reverted(event: RollbackEvent) -> void:
	actor.play_animation(&"idle")
	var payload: Dictionary = _decode_payload(event.payload)
	var kind: Variant = payload.get("kind")
	if kind == _EVENT_LIGHT_PROJECTILE or kind == _EVENT_HEAVY_PROJECTILE:
		_free_projectile(event.payload)
	elif kind == _EVENT_HEAVY_HOLD:
		_free_charge_vfx(event.payload)


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


func _decode_payload(payload: PackedByteArray) -> Dictionary:
	var decoded: Variant = bytes_to_var(payload)
	if decoded is Dictionary:
		return decoded

	return {}


func _get_payload_direction(payload: Dictionary) -> Vector3:
	var direction: Variant = payload.get("direction", Vector3.ZERO)
	if direction is Vector3:
		return direction

	return Vector3.ZERO


func _get_stream_id() -> PackedByteArray:
	return String(get_path()).to_utf8_buffer()


func _payload_key(payload: PackedByteArray) -> String:
	return payload.hex_encode()


func _free_projectile(payload: PackedByteArray) -> void:
	var payload_key: String = _payload_key(payload)
	if not _active_projectiles.has(payload_key):
		return

	var projectile: Variant = _active_projectiles[payload_key]
	_active_projectiles.erase(payload_key)
	if projectile is Node and is_instance_valid(projectile):
		(projectile as Node).queue_free()


func _free_charge_vfx(payload: PackedByteArray) -> void:
	var payload_key: String = _payload_key(payload)
	if not _active_charge_vfx.has(payload_key):
		return

	var vfx: Variant = _active_charge_vfx[payload_key]
	_active_charge_vfx.erase(payload_key)
	if vfx is Node and is_instance_valid(vfx):
		(vfx as Node).queue_free()


func _free_charge_vfx_for_kind(kind: StringName) -> void:
	for payload_key_variant: Variant in _active_charge_vfx.keys():
		var payload_key: String = payload_key_variant
		var payload: PackedByteArray = PackedByteArray.hex_decode(payload_key)
		var payload_data: Dictionary = _decode_payload(payload)
		if payload_data.get("kind") != kind:
			continue

		_free_charge_vfx(payload)
