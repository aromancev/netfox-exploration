class_name RollbackEventStream
extends RefCounted

signal event_applied(event: RollbackEvent)
signal event_reverted(event: RollbackEvent)
signal event_evicted(event: RollbackEvent)

var _id: PackedByteArray
var _events: Array[Array] = []
var _ticks: PackedInt32Array = PackedInt32Array()


func _init(id: PackedByteArray) -> void:
	_id = id.duplicate()
	_events.resize(maxi(1, NetworkRollback.history_limit))
	_ticks.resize(_events.size())
	_ticks.fill(-1)


func append_event(event: RollbackEvent) -> void:
	event.tick = NetworkRollback.tick
	var events: Array[RollbackEvent] = get_events_for_tick(event.tick)
	events.append(event)
	replace_events_for_tick(event.tick, events)


func get_events_for_tick(tick: int) -> Array[RollbackEvent]:
	var slot_index: int = tick % _events.size()
	if _ticks[slot_index] != tick:
		return []

	var events_variant: Variant = _events[slot_index]
	if events_variant == null:
		return []

	var events: Array[RollbackEvent] = []
	events.assign(events_variant)
	return events


func replace_events_for_tick(tick: int, events: Array[RollbackEvent]) -> bool:
	var capacity: int = _events.size()
	if tick < NetworkRollback.tick - capacity + 1:
		return false

	var current_events: Array[RollbackEvent] = get_events_for_tick(tick)
	var slot_index: int = tick % capacity
	var slot_events: Array[RollbackEvent] = _get_slot_events(slot_index)
	if not slot_events.is_empty() and _ticks[slot_index] != tick:
		for event: RollbackEvent in slot_events:
			event_evicted.emit(event)

	var copied_events: Array[RollbackEvent] = []
	for event: RollbackEvent in events:
		event.tick = tick
		copied_events.append(event)
	_events[slot_index] = copied_events
	_ticks[slot_index] = tick

	return _emit_corrections(current_events, copied_events)


func clear_tick(tick: int) -> void:
	replace_events_for_tick(tick, [])


func clear_tick_silently(tick: int) -> void:
	var capacity: int = _events.size()
	if tick < NetworkRollback.tick - capacity + 1:
		return

	var slot_index: int = tick % capacity
	var slot_events: Array[RollbackEvent] = _get_slot_events(slot_index)
	if not slot_events.is_empty() and _ticks[slot_index] != tick:
		for event: RollbackEvent in slot_events:
			event_evicted.emit(event)

	_events[slot_index] = []
	_ticks[slot_index] = tick


func emit_corrections_for_tick(tick: int, previous_events: Array[RollbackEvent]) -> bool:
	return _emit_corrections(previous_events, get_events_for_tick(tick))


func get_events() -> Array[RollbackEvent]:
	var current_tick: int = NetworkRollback.tick
	if current_tick < 0:
		return []

	var events: Array[RollbackEvent] = []
	var earliest_tick: int = maxi(0, current_tick - _events.size() + 1)
	for tick: int in range(earliest_tick, current_tick + 1):
		events.append_array(get_events_for_tick(tick))

	return events


func _emit_corrections(
	previous_events: Array[RollbackEvent], current_events: Array[RollbackEvent]
) -> bool:
	var unmatched_new_events: Array[RollbackEvent] = []
	unmatched_new_events.assign(current_events)
	var has_correction: bool = false
	for previous_event: RollbackEvent in previous_events:
		var matched_index: int = _find_matching_event_index(unmatched_new_events, previous_event)
		if matched_index >= 0:
			unmatched_new_events.remove_at(matched_index)
		else:
			has_correction = true
			event_reverted.emit(previous_event)

	for event: RollbackEvent in unmatched_new_events:
		has_correction = true
		event_applied.emit(event)

	return has_correction


func _find_matching_event_index(events: Array[RollbackEvent], target: RollbackEvent) -> int:
	for i: int in events.size():
		if events[i].payload == target.payload:
			return i

	return -1


func _get_slot_events(slot_index: int) -> Array[RollbackEvent]:
	var events_variant: Variant = _events[slot_index]
	if events_variant == null:
		return []

	var events: Array[RollbackEvent] = []
	events.assign(events_variant)
	return events
