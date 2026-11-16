---
id: tickets-and-rentals
title: Tickets, passes and rentals
summary: How a house sells or gives admission for a window, and how the switch enforces the door and the ticket's life.
sources: lib/junderground/rooms.ex, lib/junderground/rentals.ex, lib/junderground/router.ex
routes: POST /v1/rooms/:handle/:room/tickets; GET /v1/rooms/:handle/:room/tickets; POST /v1/rooms/:handle/:room/passes; GET /v1/rooms/:handle/:room/passes; GET /v1/rooms/:handle/:room/door; POST /v1/rooms/:handle/:room/rentals; GET /v1/rooms/:handle/:room/rentals; GET /v1/rooms/:handle/:room/rentals/active; POST /v1/rooms/:handle/:room/rentals/:id/cancel
settings: rent_block_seconds; rent_rate_percent; rent_base_fee; rent_currency
stores: rooms.dets; rentals.dets
errors: ticket_required; ticket_spent; ticket_not_found; wrong_room; not_open; door_closed; overlap; outside_rental; bad_window; window_too_long; bad_guest_window; expired; forbidden
related: rooms-and-grants; admission; signaling-and-sfu; admin-and-errors
verified: 2026-11-16
---

# Tickets, passes and rentals

A rental is a signed time window on a room, stored in `rentals.dets`. The record names the handle, room, `start` and `end`, a label, an optional event, sku and capacity, and optionally a `guest_start`/`guest_end` sub-window. Windows must be positive and at most twelve hours, and rentals for the same room may not overlap. `POST /v1/rooms/:handle/:room/rentals` creates one; `GET .../rentals` lists the schedule; `GET .../rentals/active` returns the current window or `409 not_open`; `POST .../rentals/:id/cancel` frees it.

A room with rentals is closed outside them. The owner may enter to set up; everyone else needs the active window. Guests are admitted only inside the guest window, down to a minute of a twelve-hour block, while the citizen and residents use the whole block. Every grant and ticket minted during a window is clamped to its end, so a concert ticket cannot outlive the show. `GET /v1/rooms/:handle/:room/door` reports the state the client must enforce:

- `reserved` — a future rental exists and the room is not yet in its notice period.
- `notice` — within five minutes of the start; non-ticketed occupants are warned.
- `closing` — the last minute; no new non-ticketed grant is issued (`403 door_closed`).
- `in_window` — the rental is active; non-ticketed presence entries are evicted at the start.
- `open` — no rental is currently gating the room.

A ticket is a grant with `kind: "ticket"`; a pass is a role you carry. `POST /v1/rooms/:handle/:room/tickets` issues a ticket as the room owner, and the token route spends it. The rule is: you buy a ticket, you carry a pass. A **bound** ticket names one subject and only that subject may spend it; a **bearer** ticket has no subject and any admitted house may spend one use. A ticket carries a use count, capabilities, optional opaque `meta` for the seller (sku, seat, event), optional `grants` for the store, and a signed `warranty`. It is stored server-side and spent one use at a time by `POST /v1/rooms/:handle/:room/token` with `{"ticket": "JG1..."}`. A spent, expired, revoked, wrong-room or wrong-subject ticket is refused. `GET .../tickets` is owner-only and lists what is outstanding, including uses left and expiry.

A **resident pass** is a free, bound ticket with `role: "resident"`; `POST .../passes` issues one, and `GET .../passes` lists the residents. The three room roles are `citizen` (the house that signed the rental, or the room owner), `resident` (band, manager, publicist, entourage) and `guest` (a paying attendee or a visitor). A resident pass cannot mint tickets; only the owner can issue tickets and passes. A citizen ticket in jawnos is a delegated login to a relationship's manager, not a room ticket, and the switch never stores it.

The switch quotes fees; it never charges. `GET /v1/rental_quote` (described in Getting started) returns a flat fee from the administrator's rate table, with `rent_block_seconds` setting the block length and `rent_rate_percent` the specificity discount. The renter's guest price is recorded as data for jawnos' store, which performs the sale and the payment. The switch answers only whether a ticket may enter this room and until when.
