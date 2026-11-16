---
id: getting-started
title: Getting started
summary: Run the switch, read its identity, and inspect the public surface before any house signs a record.
sources: lib/junderground/router.ex, lib/junderground/sfu.ex, lib/junderground/rentals.ex, lib/junderground/directory.ex, README.md
routes: GET /v1/meta; GET /v1/rental_quote; GET /v1/feed
settings: port; public_url; data_dir
stores: houses.dets; rooms.dets; rentals.dets; peers.dets
errors: not_found; bad_scope
related: identity-and-records; constructs-and-dial; rooms-and-grants; admin-and-errors
verified: 2026-11-16
---

# Getting started

junderground is a headless switch: JSON over HTTP, no browser session, no cookie. It keeps a signed directory of houses and issues short-lived room grants; it never runs jawnos and it never carries media. Start it from the repository root with `mix deps.get`, `mix test`, then `PORT=4100 mix run --no-halt`. On first boot it writes its Ed25519 identity to `data/server.key` (mode 0600) and opens the DETS stores named in each topic under `data_dir`.

`GET /v1/meta` is the first call to make. It returns the switch's public key, version, `public_url`, feature list, admission policy, construct suggestions, TURN URLs and the SFU block. A client should pin the public key (or the `public_url`) and verify grants with it; the `sfu` block is always present so "unconfigured" (`url: null`) is distinguishable from "configured but down". The `features` list only includes `sfu` while the cached health answer says the media server is up.

`GET /v1/feed` is the public, self-verifying bundle a relay can re-serve: advertised rooms of admitted houses, each room's signed record and rentals, plus the peers this switch admits. Every room and rental carries its own signature, so a relay may be stale but never authoritative. `GET /v1/rental_quote` returns the administrator's flat rental quote from the construct scope and a block count; an empty scope is refused with `bad_scope`.

Public reads need no signature. Everything that writes, and every read of a private house, is a signed request, which is why the next topic is identity. Keep the boundary in view: no phone numbers, no PSTN termination, no 911 routing, and media is chat-room class rather than a telephone system. The detailed contract is `docs/API.md`; the media design is `docs/SFU.md`.
