extends Weapon

enum Stage {
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
	return []


func _rollback_tick(_delta: float, tick: int, _is_fresh: bool) -> void:
	if synchronizer.is_predicting():
		return

	var is_heavy: bool = input.is_action_long_pressed("action_primary")
	var is_light: bool = not is_heavy and input.is_action_just_pressed("action_primary")
	var state: Dictionary = _get_current_state(tick)
	var attack_stage: int = state.get("stage", Stage.NONE)
	var stage_started_at: int = state.get("started_at", -1)

	if is_light and attack_stage == Stage.NONE:
		_append_projectile_event(_EVENT_LIGHT_PROJECTILE)
		return

	if (
		attack_stage == Stage.LIGHT
		and NetworkTime.seconds_between(stage_started_at, tick) >= _LIGHT_DURATION
	):
		_append_event(_EVENT_RECOVER)
		return

	if is_heavy and attack_stage == Stage.NONE:
		_append_event(_EVENT_HEAVY_HOLD)
		return

	if attack_stage == Stage.HEAVY and not is_heavy:
		var heavy_charge_elapsed: float = NetworkTime.seconds_between(stage_started_at, tick)
		if heavy_charge_elapsed >= _HEAVY_CHARGE_DURATION:
			_append_projectile_event(_EVENT_HEAVY_PROJECTILE)
		else:
			_append_event(_EVENT_RECOVER)


func _get_current_state(tick: int) -> Dictionary:
	var events: Array[RollbackEvent] = _event_stream.get_events()
	for i: int in range(events.size() - 1, -1, -1):
		var event: RollbackEvent = events[i]
		var payload: Dictionary = _decode_payload(event.payload)
		var kind: Variant = payload.get("kind")
		if kind == _EVENT_LIGHT_PROJECTILE:
			return {"stage": Stage.LIGHT, "started_at": event.tick}
		if kind == _EVENT_HEAVY_HOLD:
			return {"stage": Stage.HEAVY, "started_at": event.tick}
		if kind == _EVENT_HEAVY_PROJECTILE or kind == _EVENT_RECOVER:
			if NetworkTime.seconds_between(event.tick, tick) < _RECOVER_DURATION:
				return {"stage": Stage.RECOVER, "started_at": event.tick}

			return {"stage": Stage.NONE, "started_at": -1}

	return {"stage": Stage.NONE, "started_at": -1}


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
		event.local_context = _spawn_projectile(light_projectile, light_direction)
	elif kind == _EVENT_HEAVY_HOLD:
		actor.play_animation(&"attack_hold")
		event.local_context = _spawn_charge_vfx()
	elif kind == _EVENT_HEAVY_PROJECTILE:
		_revert_latest_event_of_kind(_EVENT_HEAVY_HOLD)
		actor.play_animation(&"attack_release")
		var heavy_direction: Vector3 = _get_payload_direction(payload)
		event.local_context = _spawn_projectile(heavy_projectile, heavy_direction)
	elif kind == _EVENT_RECOVER:
		_revert_latest_event_of_kind(_EVENT_HEAVY_HOLD)
		actor.play_animation(&"idle")


func _on_event_reverted(event: RollbackEvent) -> void:
	actor.play_animation(&"idle")
	var payload: Dictionary = _decode_payload(event.payload)
	var kind: Variant = payload.get("kind")
	if kind == _EVENT_LIGHT_PROJECTILE or kind == _EVENT_HEAVY_PROJECTILE:
		_revert_local_context(event)
	elif kind == _EVENT_HEAVY_HOLD:
		_revert_local_context(event)


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


func _revert_latest_event_of_kind(kind: StringName) -> void:
	var events: Array[RollbackEvent] = _event_stream.get_events()
	for i: int in range(events.size() - 1, -1, -1):
		var event: RollbackEvent = events[i]
		var payload: Dictionary = _decode_payload(event.payload)
		if payload.get("kind") != kind:
			continue

		_revert_local_context(event)
		return


func _revert_local_context(event: RollbackEvent) -> void:
	if not (event.local_context is Node):
		return

	var node: Node = event.local_context
	event.local_context = null
	if is_instance_valid(node):
		node.queue_free()
