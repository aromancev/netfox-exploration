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

Very complex to backtrack what happened on resim. have to keep additional state.

### `using_multiple_rewindable_actions.gd`
Uses separate `RewindableAction`s for light, heavy hold, and heavy release.

**Idea:** split the weapon into several smaller rollback-aware actions.

More straightforward than one RA but paying with additional network traffic **for each weapon state**. Yikes!

### `using_effects.gd`
Uses `RollbackEffects` to record and deduplicate local presentation effects.

**Idea:** gameplay state drives the weapon, and effects are recorded separately so resimulation can keep or revert them. This is conceptually the same as https://react.dev/reference/react/useEffect.

Straightforward apply and revert of events. Zero network cost. Low complexity. Effect deduplication keys are not immediately obvious. Possibly some synchronization edge case I'm not seeing?

### `using_event_log.gd`
Uses a single per-weapon `RollbackEventLog` stream.

**Idea:** append weapon events and reconstruct current state from event history, while local spawned objects live in `event.local_context`.

No need for synced variables at all. Everything is reconstructed deterministically from events. High complexity of state aggregates. Higher complexity of synchronization than RAs.