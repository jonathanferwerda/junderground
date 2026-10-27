# junderground checkpoint

## Agent: DeepSeek V4.1 Flash (Zed) — 2026-10-26 23:00 UTC

Goal: v0.1.3 — partial dial scopes, room rentals and event windows, bearer
event tickets, and the citizen-ticket boundary.

Done:
- `constructs.ex` rewritten: blank constructs are undefined (wildcards), rooms
  match by `room_scope ⊆ dial`, `scope_id`, suggestions only for the UI.
- `rentals.ex`: signed windows (≤ 12h, no overlap), active/next, `open_for`,
  cancel; rooms closed outside their windows; grants and tickets clamped to the
  window end.
- `rooms.ex`: `dial/1`, `scope`, ticket `bind` (subject/bearer), `meta`, rental
  claim, rental-aware verification.
- `router.ex`: rentals endpoints, new dial response, ticket fields.
- Docs: partial dial, rentals, citizen-vs-room ticket boundary.
- 73 tests pass.

Next:
1. Commit v0.1.3 (this file goes with it).
2. Signaling channel + SFU adapter.
3. jawnos client: partial dial, roster grading, join, event ticket purchase.
4. Chat app Underground section and the rental editor.
