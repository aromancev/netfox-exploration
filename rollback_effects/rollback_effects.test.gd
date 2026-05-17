extends VestTest

const RollbackEffects = preload("res://platform/rollback_effects/rollback_effects.gd")


class Tracker:
	extends RefCounted

	var apply_calls: int = 0
	var revert_calls: int = 0

	func apply_with_revert(ctx: Variant) -> void:
		apply_calls += 1
		ctx.on_revert = on_revert

	func apply_without_revert(_ctx: Variant) -> void:
		apply_calls += 1

	func on_revert() -> void:
		revert_calls += 1


func _get_suite_name() -> String:
	return "RollbackEffects"


func suite() -> void:
	test(
		"Skips duplicate key on the same tick",
		func() -> void:
			var effects := _create_effects()
			var tracker := Tracker.new()

			effects.call("record", "coin", tracker.apply_with_revert, 10)
			effects.call("record", "coin", tracker.apply_with_revert, 10)
			NetworkRollback.after_process_tick.emit(10)

			expect_equal(tracker.apply_calls, 1)
			expect_equal(tracker.revert_calls, 0)
			effects.free()
	)

	test(
		"Reserves duplicate key even without revert callback",
		func() -> void:
			var effects := _create_effects()
			var tracker := Tracker.new()

			effects.call("record", "coin", tracker.apply_without_revert, 10)
			effects.call("record", "coin", tracker.apply_without_revert, 10)
			NetworkRollback.after_process_tick.emit(10)

			expect_equal(tracker.apply_calls, 1)
			effects.free()
	)

	test(
		"Reverts only effects that were not recorded on resim",
		func() -> void:
			var effects := _create_effects()
			var kept := Tracker.new()
			var reverted := Tracker.new()

			effects.call("record", "keep", kept.apply_with_revert, 10)
			effects.call("record", "drop", reverted.apply_with_revert, 10)

			NetworkRollback.on_prepare_tick.emit(10)
			effects.call("record", "keep", kept.apply_with_revert, 10)
			NetworkRollback.after_process_tick.emit(10)

			expect_equal(kept.apply_calls, 1)
			expect_equal(kept.revert_calls, 0)
			expect_equal(reverted.apply_calls, 1)
			expect_equal(reverted.revert_calls, 1)
			effects.free()
	)

	test(
		"Wrapped history slot does not keep old keys",
		func() -> void:
			var effects := _create_effects()
			var tracker := Tracker.new()
			var tick: int = 7
			var wrapped_tick: int = tick + NetworkRollback.history_limit

			effects.call("record", "coin", tracker.apply_with_revert, tick)
			effects.call("record", "coin", tracker.apply_with_revert, wrapped_tick)
			NetworkRollback.after_process_tick.emit(wrapped_tick)

			expect_equal(tracker.apply_calls, 2)
			expect_equal(tracker.revert_calls, 0)
			effects.free()
	)


func _create_effects() -> Node:
	var effects := RollbackEffects.new()
	effects._ready()
	return effects
