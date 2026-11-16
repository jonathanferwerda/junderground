---
id: identity-and-records
title: Identity and records
summary: How a house or peer proves its key, how its record chain is stored, and why registering is not admission.
sources: lib/junderground/record.ex, lib/junderground/directory.ex, lib/junderground/peers.ex, lib/junderground/auth.ex, lib/junderground/canonical.ex, lib/junderground/keys.ex, lib/junderground/router.ex
routes: POST /v1/peers; GET /v1/peers; GET /v1/peers/:id; POST /v1/houses; POST /v1/houses/:handle/records; GET /v1/houses/:handle; GET /v1/houses/:handle/records; GET /v1/directory; POST /v1/mirror
settings: data_dir
stores: houses.dets; peers.dets
errors: replay; taken; stale; gap; broken_chain; wrong_key; not_registered; bad_first_seq; retired; unknown_house; not_found; not_admitted; forbidden
related: admission; getting-started; admin-and-errors; rooms-and-grants
verified: 2026-11-16
---

# Identity and records

A house record is a self-signed statement of who a house is, where it can be reached and which statement supersedes which. The format is `junderground-house`; `kind` is `register`, `route`, `rotate` or `tombstone`. The signature is Ed25519 over the canonical JSON of every field except `sig`, using the same canonical encoder as jawnos crests. Signed payloads contain strings, integers, lists and maps only: no floats, booleans or null; use the strings `"allow"` and `"off"` for flags. The record's `pubkey` is inside the signed bytes, so it cannot be swapped. When a record carries a `crest` block, its `pubkey` must be the same key; the crest is the identity, not a separate claim.

The directory is append-only in `houses.dets`. The chain rules are the contract: `seq` starts at 1 and steps by exactly one, `prev` is the signature of the record being superseded, a `rotate` is signed by the old key and names `new_pubkey`, and a `tombstone` retires a handle. First writer wins a handle. A different key cannot take it over even after a tombstone; the same key may return with a higher `seq`. A divergence is reported as `stale`, `gap`, `broken_chain`, `wrong_key` or `taken` rather than silently chosen. `GET /v1/houses/:handle` returns the current record and its admission entry; `GET /v1/houses/:handle/records?since=` returns history oldest first. A tombstoned handle answers `410 retired`.

`POST /v1/houses` needs no request signature because the record itself is signed; the later `POST /v1/houses/:handle/records` writes are signed requests. A signed request carries `X-JG-Handle`, `X-JG-Timestamp`, `X-JG-Nonce` and `X-JG-Signature`; the signature covers method, path and query, the body hash, the timestamp and the nonce. The timestamp must be within ±300 seconds and a reused nonce is `409 replay`. Visibility matters: `public` records are readable, while `unlisted` and `sealed` records require the owning house's signed request and are never included in the public directory feed.

Peers are other switches, not houses. They register a `junderground-peer` record, use their own key in `X-JG-Peer`, and go through the same six admission states. Only an `approved` peer may push records into `POST /v1/mirror`; `probation` may read but not push. `GET /v1/peers` lists approved and probation peers, and `GET /v1/peers/:id` returns one of those; others answer `404`. Each mirrored record is still verified on its own, so a mirror cannot inject a record a house did not sign. `GET /v1/directory` is the public feed for caches and includes only admitted houses with `public` visibility; `GET /v1/feed` carries the room and rental bundle described in Getting started.

Registration is not admission. The first record opens a `pending` admission entry, and an administrator moves it; that separate decision is the subject of the Admission topic. Do not treat a stored record as permission to use this switch.
