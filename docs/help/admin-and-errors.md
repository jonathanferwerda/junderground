---
id: admin-and-errors
title: Administrator surface and errors
summary: The admin-signed peer routes, the error contract, and where the switch's authority stops.
sources: lib/junderground/admin.ex, lib/junderground/peers.ex, lib/junderground/admission.ex, lib/junderground/router.ex
routes: GET /v1/admin/peers; GET /v1/admin/peers/queue; GET /v1/admin/peers/audit; POST /v1/admin/peers/:id/status; ANY *
settings: admin_keys
stores: peers.dets; admission.dets
errors: not_found; room_full; unknown_house; missing_auth; stale_timestamp; bad_timestamp; forbidden; not_admin; not_admitted; invite_required; retired; expired; room_closed; ticket_required; ticket_spent; ticket_not_found; wrong_room; bad_grant; not_open; door_closed; overlap; outside_rental; bad_window; window_too_long; bad_label; bad_event; bad_sku; bad_capacity; bad_bind; bad_meta; bad_uses; bad_expires; bad_scope; bad_guest_window; bad_citizen; bad_fee; bad_guest_price; bad_currency; bad_role; bad_grants; bad_warranty; bad_lexicon; bad_language; replay; taken; stale; gap; broken_chain; wrong_key; not_registered; bad_first_seq; rate_limited; revoked; not_websocket
related: admission; identity-and-records; constructs-and-dial; rooms-and-grants
verified: 2026-11-16
---

# Administrator surface and errors

The administrator surface is deliberately small and signed with a crest key from `admin_keys` in `X-JG-Admin`, never a house handle. House admission, reports and reviews are covered in Admission; the remaining administrator routes are for peers, the other jundergrounds. `GET /v1/admin/peers` returns the peer list and its queue, `GET /v1/admin/peers/queue` returns the pending and probation queue, and `GET /v1/admin/peers/audit?since=` returns the decision log. `POST /v1/admin/peers/:id/status` moves a peer through the same six states as a house: `pending`, `approved`, `probation`, `suspended`, `rejected` or `banned`. Only an `approved` peer may push records into `POST /v1/mirror`; `probation` is read-only. Every decision is recorded with the operator as `admin:<key prefix>`.

The administrator decides admission for this switch and nothing more. It cannot alter a house's signed record, impersonate a house, or turn a record into permission. Admin keys live in configuration; they are never placed in a record, a log line or the repository. The fallback route `ANY *` answers `404 not_found` and is the boundary for an unknown method or path.

Errors are JSON: `{"error":{"code":"..."}}`. The code is the atom; the HTTP status is fixed by the router. The groups are:

- `401` — `missing_auth`, `stale_timestamp`, `bad_timestamp`: a signed request is missing headers or outside the ±300-second window.
- `403` — `forbidden`, `not_admin`, `not_admitted`, `invite_required`, `ticket_required`, `door_closed`, `wrong_room`: the caller or the presented credential is not allowed for this action or room.
- `404` — `not_found`, `unknown_house`, `ticket_not_found`: the handle, room, route or issued ticket does not exist, or is private to the caller.
- `409` — `room_full`, `ticket_spent`, `not_open`, `overlap`, `outside_rental`, `revoked`, `replay`, `taken`, `stale`, `gap`, `broken_chain`, `wrong_key`, `not_registered`, `bad_first_seq`: a state conflict, a spent ticket, a replayed nonce, a lost handle or a chain that does not extend the stored one.
- `410` — `retired`, `expired`, `room_closed`: the handle is tombstoned, the room or grant is past its expiry, or the room's house is not admitted.
- `422` — `bad_grant`, `bad_window`, `window_too_long`, `bad_label`, `bad_event`, `bad_sku`, `bad_capacity`, `bad_bind`, `bad_meta`, `bad_uses`, `bad_expires`, `bad_scope`, `bad_guest_window`, `bad_citizen`, `bad_fee`, `bad_guest_price`, `bad_currency`, `bad_role`, `bad_grants`, `bad_warranty`, `bad_lexicon`, `bad_language`: a malformed or out-of-range field. Any atom not listed above falls through to `422` as well.
- `426` — `not_websocket`: the signaling route was called without a WebSocket upgrade.
- `429` — `rate_limited`: an application or another rate-limited ingress was called too often.
- `503` — `sfu_unavailable` is returned directly by the SFU token route with `Retry-After: 30` when the room needs an SFU but none is configured or healthy; it is not a `status_for` atom.

The boundary is the same everywhere: no phone numbers, DIDs, PSTN termination, 911 routing or carrier obligations. A record may say who a house is and a grant may admit someone to a room, but neither makes this a telephone system.
