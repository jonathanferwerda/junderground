---
id: rooms-and-grants
title: Rooms and grants
summary: How a room policy becomes a short-lived grant, and what the grant can do.
sources: lib/junderground/rooms.ex, lib/junderground/rentals.ex, lib/junderground/router.ex, lib/junderground/token.ex, lib/junderground/turn.ex
routes: POST /v1/rooms; GET /v1/rooms/:handle; GET /v1/rooms/:handle/:room; POST /v1/rooms/:handle/:room/token; POST /v1/rooms/:handle/:room/revoke; POST /v1/rooms/:handle/:room/presence; POST /v1/rooms/:handle/:room/presence/leave; GET /v1/rooms/:handle/:room/presence
settings: grant_ttl; public_url
stores: rooms.dets
errors: room_closed; ticket_required; ticket_spent; not_admitted; invite_required; forbidden; retired; expired; wrong_room; revoked; bad_grant
related: admission; constructs-and-dial; tickets-and-rentals; signaling-and-sfu
verified: 2026-11-16
---

# Rooms and grants

A room is a policy record signed by the owning house's key, stored in `rooms.dets`. It names the handle, room slug, constructs, `advertised`, `policy`, `max`, `recording` and optional `expires`; records use the same `seq`/`prev`/key rules as house records. `POST /v1/rooms` registers or updates one and requires a signed request from the same handle. An existing room may be written while its house is `pending`, `approved` or `probation`; a new room requires `approved`. `GET /v1/rooms/:handle` lists the house's rooms and `GET /v1/rooms/:handle/:room` returns one. The single-room read is allowed for an admitted house or its owner; otherwise it answers `410 room_closed`.

The policy decides who may enter: `open` admits any admitted house, `house` admits only the owner, `invite` needs an invite grant or a ticket, `direct` admits a handle in `members`, and `ticket` needs a ticket. `POST /v1/rooms/:handle/:room/token` turns a signed request plus that policy into a `JG1` grant. The grant is an Ed25519-signed token, not a JWT. It carries the room, `room_key`, subject, capabilities, issue and expiry times, `jti`, admission epoch and role. The role is `citizen` for the house that signed the room or the rental's citizen, `resident` for a resident pass, otherwise `guest`.

Capabilities are intersected with what the role and room allow. The default request is `join`, `publish_audio` and `subscribe`; a citizen also gets `moderate`, `invite` and, only when the room says `recording: "allow"`, `record`. `join` is mandatory, and an empty intersection is `403`. A ticket presented with the grant is consumed at this point, so a private or ticket room is admitted by spending it rather than by a claim in the request. The expiry is clamped to the room's `expires` and to the active rental or guest window. A house on probation is clamped further to five minutes and to audio-only capabilities. `iss` is the configured `public_url`; TURN credentials are returned alongside the grant and are as short-lived as the grant.

Revocation is by `jti`. `POST /v1/rooms/:handle/:room/revoke` is owner-only, stores the `jti` until its supplied expiry (or an hour by default), and the grant stops verifying immediately. A revoked token is `409 revoked`; an expired one is `410 expired`; a grant presented for another room is `403 wrong_room`; a malformed grant is `422 bad_grant`.

Presence is the room's roster, not its media plane. A client joins with the grant it already holds; the entry is keyed by the grant's `jti` and carries the subject, capabilities and an expiry that defaults to 120 seconds. A client refreshes with the same call and leaves explicitly with `POST .../presence/leave`; a crashed client disappears when its heartbeat lapses. `GET .../presence` returns the roster for an `open` or advertised room, or for the owner; a private room returns it only to its owner. The switch publishes handles and capabilities only. It never receives a people list or the relationship graph; the house grades the roster locally before opening the room. Tickets, passes and rental doors are detailed in the next two topics, and the WebSocket is in Signaling and the SFU.
