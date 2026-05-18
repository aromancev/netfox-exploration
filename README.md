# Weapon rollback demos

This repo shows a few different ways to implement the same simple weapon behavior:

- tap for a light projectile
- hold to charge a heavy attack
- release after enough charge to fire a heavy projectile
- early release goes to recover without firing
- both attacks have recover time

## Demos

### `using_one_rewindable_action.gd`
Uses one `RewindableAction` for the whole weapon.

**Idea:** treat the weapon as one rollback-aware action with different local phases.

### `using_multiple_rewindable_actions.gd`
Uses separate `RewindableAction`s for light, heavy hold, and heavy release.

**Idea:** split the weapon into several smaller rollback-aware actions.

### `using_effects.gd`
Uses `RollbackEffects` to record and deduplicate local presentation effects.

**Idea:** gameplay state drives the weapon, and effects are recorded separately so resimulation can keep or revert them.

### `using_event_log.gd`
Uses a single per-weapon `RollbackEventLog` stream.

**Idea:** append weapon events and reconstruct current state from event history, while local spawned objects live in `event.local_context`.
