class_name RollbackEventLog
extends Node

@export_range(1, 32, 1, "or_greater") var replicated_ticks: int = 3

var _streams: Dictionary[PackedByteArray, RollbackEventStream] = {}
var _prepared_events_by_tick: Dictionary[int, Dictionary] = {}


func _ready() -> void:
	NetworkTime.after_tick_loop.connect(_replicate_recent_ticks)
	NetworkRollback.on_prepare_tick.connect(_on_prepare_tick)
	NetworkRollback.after_process_tick.connect(_after_process_tick)


func get_stream(id: PackedByteArray) -> RollbackEventStream:
	if not _streams.has(id):
		_streams[id] = RollbackEventStream.new(id)

	return _streams[id]


func _replicate_recent_ticks() -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return

	var latest_tick: int = NetworkRollback.tick
	var earliest_tick: int = maxi(0, latest_tick - replicated_ticks + 1)
	for tick: int in range(earliest_tick, latest_tick + 1):
		_submit_tick.rpc(_encode_tick_payload(tick), tick)


func _encode_tick_payload(tick: int) -> PackedByteArray:
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	var stream_count_position: int = buffer.get_position()
	buffer.put_u16(0)

	var stream_count: int = 0
	for stream_id_variant: Variant in _streams:
		var stream_id: PackedByteArray = stream_id_variant
		var events: Array[RollbackEvent] = (
			(_streams[stream_id] as RollbackEventStream).get_events_for_tick(tick)
		)
		if events.is_empty():
			continue

		stream_count += 1
		buffer.put_u16(stream_id.size())
		buffer.put_data(stream_id)
		buffer.put_u16(events.size())
		for event: RollbackEvent in events:
			buffer.put_u32(event.payload.size())
			buffer.put_data(event.payload)

	var end_position: int = buffer.get_position()
	buffer.seek(stream_count_position)
	buffer.put_u16(stream_count)
	buffer.seek(end_position)

	return buffer.data_array


@rpc("authority", "call_remote", "reliable")
func _submit_tick(data: PackedByteArray, tick: int) -> void:
	var applied_streams: Dictionary[PackedByteArray, bool] = {}
	var had_correction: bool = false
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.data_array = data

	var stream_count: int = buffer.get_u16()
	for _i: int in stream_count:
		var stream_id_result: Array = buffer.get_data(buffer.get_u16())
		if stream_id_result[0] != OK:
			return

		var stream_id: PackedByteArray = stream_id_result[1]
		applied_streams[stream_id] = true

		var event_count: int = buffer.get_u16()
		var events: Array[RollbackEvent] = []
		for _j: int in event_count:
			var payload_result: Array = buffer.get_data(buffer.get_u32())
			if payload_result[0] != OK:
				return

			var event: RollbackEvent = RollbackEvent.new()
			event.tick = tick
			event.payload = payload_result[1]
			events.append(event)

		if get_stream(stream_id).replace_events_for_tick(tick, events):
			had_correction = true

	for stream_id_variant: Variant in _streams:
		var stream_id: PackedByteArray = stream_id_variant
		if applied_streams.has(stream_id):
			continue

		if (_streams[stream_id] as RollbackEventStream).replace_events_for_tick(tick, []):
			had_correction = true

	if had_correction:
		NetworkRollback.notify_resimulation_start(tick)


func _on_prepare_tick(tick: int) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return

	var prepared_events: Dictionary = {}
	for stream_id_variant: Variant in _streams:
		var stream_id: PackedByteArray = stream_id_variant
		var stream: RollbackEventStream = _streams[stream_id]
		var previous_events: Array[RollbackEvent] = stream.get_events_for_tick(tick)
		if not previous_events.is_empty():
			prepared_events[stream_id] = previous_events
		stream.clear_tick_silently(tick)

	_prepared_events_by_tick[tick] = prepared_events


func _after_process_tick(tick: int) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return

	var prepared_events: Dictionary = _prepared_events_by_tick.get(tick, {})
	for stream_id_variant: Variant in _streams:
		var stream_id: PackedByteArray = stream_id_variant
		var previous_events: Array[RollbackEvent] = prepared_events.get(stream_id, [])
		(_streams[stream_id] as RollbackEventStream).emit_corrections_for_tick(
			tick, previous_events
		)

	_prepared_events_by_tick.erase(tick)
