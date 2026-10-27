# junderground checkpoint

## Agent: DeepSeek V4.1 Flash (Zed) — 2026-10-26 23:30 UTC

Goal: v0.1.5 — rental door policy, then the jawnos ticket→pass rename.

Done:
- `rentals.ex`: `door/2` (reserved / notice / closing / in_window), setup window
  of 5 minutes for citizen and residents.
- `rooms.ex`: `ticketed`, door policy in `grant`, `door_closed` in
  `verify_grant_token`.
- `presence.ex`: `ticketed`, `notify_at`, `evict_at`; eviction on read.
- `router.ex`: `/v1/rooms/:h/:r/door`; presence carries the door.
- 83 tests pass.

Next:
1. Commit v0.1.5.
2. jawnos ticket→pass rename (subagent patch in a clean worktree).
3. Signaling + client.
