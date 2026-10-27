# junderground checkpoint

## Agent: DeepSeek V4.1 Flash (Zed) — 2026-10-26 23:10 UTC

Goal: v0.1.4 — citizen/resident/guest room roles, resident passes, guest
windows, rental fee quote and renter price, public feed for chaining.

Done:
- `rooms.ex`: role resolution (citizen/resident/guest), role caps, resident
  passes (`/passes`), tickets carry `role`, `grants`, `warranty`, guest-window
  clamping.
- `rentals.ex`: `guest_start`/`guest_end`, `citizen`, `fee`, `guest_price`,
  `Rentals.quote/2`, role-aware `open_for/4`.
- `router.ex`: `/v1/rental_quote`, `/v1/rooms/:h/:r/passes`, `/v1/feed`.
- Config: `rent_base_fee`, `rent_currency`, `rent_block_seconds`,
  `rent_rate_percent`.
- Docs: roles, fees, guest windows, the ticket/pass naming rule, feed chaining.
- 80 tests pass.

Next:
1. Commit v0.1.4 (this file goes with it).
2. Signaling channel + SFU adapter.
3. jawnos client: partial dial, role-aware join, roster grading, store tickets.
4. Chat app Underground section and rental editor.
