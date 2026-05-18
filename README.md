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

**Good for:**
- small self-contained interactions
- demos where you want one place to manage confirm/cancel behavior

**Tradeoffs:**
- one action starts carrying a lot of mixed responsibilities
- local context can get a bit crowded once different effect types pile up

### `using_multiple_rewindable_actions.gd`
Uses separate `RewindableAction`s for light, heavy hold, and heavy release.

**Idea:** split the weapon into several smaller rollback-aware actions.

**Good for:**
- cases where each step has a clear identity
- simpler per-action context and cancellation logic

**Tradeoffs:**
- more wiring
- coordination between actions becomes part of the implementation

### `using_effects.gd`
Uses `RollbackEffects` to record and deduplicate local presentation effects.

**Idea:** gameplay state drives the weapon, and effects are recorded separately so resimulation can keep or revert them.

**Good for:**
- visual/audio side effects
- cases where the important problem is effect deduplication during resim

**Tradeoffs:**
- you need solid effect identity keys
- effect lifetime is separate from action/state lifetime

### `using_event_log.gd`
Uses a single per-weapon `RollbackEventLog` stream.

**Idea:** append weapon events and reconstruct current state from event history, while local spawned objects live in `event.local_context`.

**Good for:**
- event-sourced flows
- cases where correction/replay should be modeled as replacing one event history with another
- situations where you want transport/replication to line up with the gameplay model

**Tradeoffs:**
- more infrastructure than the other demos
- deriving current state from events is powerful, but more explicit work

## Rule of thumb

- use **one rewindable action** for the smallest version
- use **multiple rewindable actions** when phases deserve separate ownership
- use **rollback effects** when state is simple but presentation must survive resim cleanly
- use **event log** when the thing really wants to be modeled as a stream of authoritative events
