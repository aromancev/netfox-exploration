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

const _STREAM_LIGHT_PROJECTILE: String = "light_projectile"
const _STREAM_HEAVY_HOLD: String = "heavy_hold"
const _STREAM_HEAVY_PROJECTILE: String = "heavy_projectile"
const _STREAM_RECOVER: String = "recover"

var _attack_stage_started_at: int = -1
var _attack_stage: int = _Stage.NONE

var _active_projectiles: Dictionary = {}
var _active_charge_vfx: Dictionary = {}

@export var input: UnitInput
@export var actor: Actor
@export var synchronizer: RollbackSynchronizer
@export var event_log: RollbackEventLog
@export var projectile_root: Node
@export var vfx_root: Node
@export var light_projectile: PackedScene
@export var heavy_projectile: PackedScene
@export var heavy_charge_vfx: PackedScene

@onready var _light_projectile_stream: RollbackEventStream = event_log.get_stream(
	_STREAM_LIGHT_PROJECTILE.to_utf8_buffer()
)
@onready var _heavy_hold_stream: RollbackEventStream = event_log.get_stream(
	_STREAM_HEAVY_HOLD.to_utf8_buffer()
)
@onready var _heavy_projectile_stream: RollbackEventStream = event_log.get_stream(
	_STREAM_HEAVY_PROJECTILE.to_utf8_buffer()
)
@onready
var _recover_stream: RollbackEventStream = event_log.get_stream(_STREAM_RECOVER.to_utf8_buffer())


func _ready() -> void:
	_light_projectile_stream.event_applied.connect(_on_light_projectile_applied)
	_light_projectile_stream.event_reverted.connect(_on_light_projectile_reverted)
	_heavy_hold_stream.event_applied.connect(_on_heavy_hold_applied)
	_heavy_hold_stream.event_reverted.connect(_on_heavy_hold_reverted)
	_heavy_projectile_stream.event_applied.connect(_on_heavy_projectile_applied)
	_heavy_projectile_stream.event_reverted.connect(_on_heavy_projectile_reverted)
	_recover_stream.event_applied.connect(_on_recover_applied)


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
		_append_projectile_event(_light_projectile_stream)
		return

	if (
		_attack_stage == _Stage.LIGHT
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _LIGHT_DURATION
	):
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		_append_empty_event(_recover_stream)
		return

	if is_heavy and _attack_stage == _Stage.NONE:
		_attack_stage_started_at = tick
		_attack_stage = _Stage.HEAVY
		_append_empty_event(_heavy_hold_stream)
		return

	if _attack_stage == _Stage.HEAVY and not is_heavy:
		var heavy_charge_elapsed: float = NetworkTime.seconds_between(
			_attack_stage_started_at, tick
		)
		_attack_stage_started_at = tick
		_attack_stage = _Stage.RECOVER
		if heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION:
			_append_projectile_event(_heavy_projectile_stream)
		else:
			_append_empty_event(_recover_stream)
		return

	if (
		_attack_stage == _Stage.RECOVER
		and NetworkTime.seconds_between(_attack_stage_started_at, tick) >= _RECOVER_DURATION
	):
		_attack_stage_started_at = -1
		_attack_stage = _Stage.NONE


func _append_projectile_event(stream: RollbackEventStream) -> void:
	var event: RollbackEvent = RollbackEvent.new()
	var direction: Vector3 = _get_projectile_direction()
	event.payload = var_to_bytes(direction)
	stream.append_event(event)


func _append_empty_event(stream: RollbackEventStream) -> void:
	var event: RollbackEvent = RollbackEvent.new()
	stream.append_event(event)


func _on_light_projectile_applied(event: RollbackEvent) -> void:
	actor.play_animation(&"attack")
	var direction: Vector3 = _decode_direction(event.payload)
	var projectile: Node = _spawn_projectile(light_projectile, direction)
	_active_projectiles[_payload_key(event.payload)] = projectile


func _on_light_projectile_reverted(event: RollbackEvent) -> void:
	actor.play_animation(&"idle")
	_free_projectile(event.payload)


func _on_heavy_hold_applied(event: RollbackEvent) -> void:
	actor.play_animation(&"attack_hold")
	var payload_key: String = _payload_key(event.payload)
	_active_charge_vfx[payload_key] = _spawn_charge_vfx()


func _on_heavy_hold_reverted(event: RollbackEvent) -> void:
	actor.play_animation(&"idle")
	_free_charge_vfx(event.payload)


func _on_heavy_projectile_applied(event: RollbackEvent) -> void:
	_free_charge_vfx(PackedByteArray())
	actor.play_animation(&"attack_release")
	var direction: Vector3 = _decode_direction(event.payload)
	var projectile: Node = _spawn_projectile(heavy_projectile, direction)
	_active_projectiles[_payload_key(event.payload)] = projectile


func _on_heavy_projectile_reverted(event: RollbackEvent) -> void:
	actor.play_animation(&"idle")
	_free_projectile(event.payload)


func _on_recover_applied(_event: RollbackEvent) -> void:
	_free_charge_vfx(PackedByteArray())
	actor.play_animation(&"idle")


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


func _decode_direction(payload: PackedByteArray) -> Vector3:
	var decoded: Variant = bytes_to_var(payload)
	if decoded is Vector3:
		return decoded

	return Vector3.ZERO


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
