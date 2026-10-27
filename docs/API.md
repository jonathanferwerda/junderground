# junderground API v1 — sketch

Status: **implemented and tested** for the directory, records, grants,
revocations and TURN credentials. Signaling, the SFU and the coturn deployment
are designed but not built. Everything below is what the code in `lib/` does
today unless it is marked *planned*.

The service is headless: JSON over HTTP, no browser session, no cookie. A small
admin UI is optional and is not part of this contract.

## 1. Design rules

1. **Signed, not trusted.** The switch stores and orders signed statements; it
   does not decide who a house is. A house keeps its own key, and can publish
   the same chain at another junderground.
2. **First writer wins a handle, and only the holder can change it.** A
   different key can never take over a handle, even after a tombstone.
3. **History is a chain, not a timestamp.** `seq` and `prev` make rollback and
   reordering detectable by clients, not just by the server.
4. **Capabilities are short-lived.** Grants live 15 minutes by default; TURN
   credentials 10. Revocation is immediate because nothing depends on a
   long-lived credential.
5. **No PSTN.** No DIDs, no 911, no carrier interconnect. A call that arrives
   from the phone network never reaches this service.
6. **The media plane is separate.** This process is the control plane; it never
   carries audio.

## 2. Encoding

### Canonical JSON

The bytes that get signed are exactly what jawnos already produces for crests:

- object keys are ASCII strings, sorted byte-wise;
- values are strings, integers, lists or nested objects;
- **no floats, booleans or null** — use the strings `"allow"` / `"off"` for flags;
- no whitespace;
- `"` and `\` escape, control characters use `\b \f \n \r \t` or `\u00XX`;
- non-ASCII is legal UTF-8 but should be avoided in signed fields.

That is `JSON::PP->new->canonical(1)` in Perl and `Junderground.Canonical` in
Elixir. `test/record_test.exs` holds a Perl-signed fixture, so a change to the
encoder fails the suite.

### Keys and signatures

- Ed25519, raw: public key 32 bytes, signature 64 bytes.
- Transport form: standard base64 **with** padding.
- A record signs the canonical JSON of every field **except `sig`**. The
  `pubkey` is inside the signed bytes, so it cannot be swapped.

## 3. Names

| Thing | Shape | Example |
| --- | --- | --- |
| Handle | `^[a-z0-9][a-z0-9._-]{1,62}$` | `alpha` |
| Room slug | `^[a-z0-9][a-z0-9._-]{0,62}$` | `lobby` |
| Room id | `handle/room` | `alpha/lobby` |
| `room_key` | lower-case hex SHA-256 of the room record's `sig` | `e077…b461` |

A fingerprint is computed for display: upper-case SHA-256 of the public key in
groups of four (`C6/P ZA4L W5IV …` in the Perl fixture).

## 4. House records

```json
{
  "format": "junderground-house",
  "version": 1,
  "kind": "register",
  "handle": "alpha",
  "name": "Alpha House",
  "pubkey": "C6/pZA4LW5IVvv8581VwHcTcjnnrOdPhcs/E9NKrYOM=",
  "seq": 1,
  "issued": 1760000000,
  "visibility": "public",
  "routes": {
    "wss": "wss://alpha.example/v1/signal",
    "tailnet": "alpha-house.ts.net"
  },
  "sig": "w23ZvmFPjt1zNnPm5GmhHt70vjhAQGsMfQXkNyaYCHg52zcD4L2qBPiZHI2VjUdHL/5uMG7X+R6a5pPrPtCqCQ=="
}
```

### Fields

| Field | Required | Notes |
| --- | --- | --- |
| `format` | yes | `junderground-house` |
| `version` | yes | `1` |
| `kind` | yes | `register`, `route`, `rotate`, `tombstone` |
| `handle` | yes | see names |
| `name` | no | display name, ≤ 200 bytes |
| `pubkey` | yes | raw 32-byte Ed25519, base64 |
| `new_pubkey` | rotate only | the key that signs later records |
| `seq` | yes | starts at 1, steps by exactly one |
| `prev` | after the first | the `sig` of the record being superseded |
| `issued` | yes | unix seconds, at most one hour in the future |
| `visibility` | no | `public` (default), `unlisted`, `sealed` |
| `routes` | no | ≤ 16 string→string pairs, value ≤ 2 KB |
| `sig` | yes | Ed25519 over the rest |

`routes` keys are open; the intended ones are `wss` (signaling), `turn`
(dedicated relay), `tailnet` (same-house optimization), `sip` (future) and
`https` (a house's own API).

### Kinds and the chain

| kind | Meaning | Rules |
| --- | --- | --- |
| `register` | first statement, or the same key returning after a tombstone | `seq = 1` when no prior; otherwise `seq = prior.seq + 1`, same key |
| `route` | new endpoints, same identity | `seq + 1`, `prev = prior.sig`, same key |
| `rotate` | move signing authority | signed by the **old** key, names `new_pubkey`; the next record carries the new key |
| `tombstone` | retire the handle | `seq + 1`, `prev`, same key; the handle is hidden from lookups |

After a rotation the directory's head `pubkey` is the new key, so a record
signed by the old key is `wrong_key`. A tombstone is permanent for other keys;
the same key may re-register with a higher `seq`.

### Visibility

- `public` — listed, readable by anyone.
- `unlisted` / `sealed` — lookup and history require this house's signed request;
  otherwise `404`. The global feed (`/v1/directory`) never includes them.
  `sealed` is currently the same as `unlisted`; field-level sealing is *planned*.

## 5. Signed requests

Every write, and every read of a non-public house, carries:

```
X-JG-Handle:    alpha
X-JG-Timestamp: 1760000000
X-JG-Nonce:     q2Z0m8r1oQd4xY7v
X-JG-Signature: <base64 Ed25519>
```

The signed message is:

```
POST
/v1/rooms/alpha/lobby/token
<lower-case hex sha256 of the raw body>
1760000000
q2Z0m8r1oQd4xY7v
```

Rules:

- timestamp within ±300 s of the switch's clock;
- nonce at least 16 characters, remembered for the window; reuse is `409 replay`;
- `GET` bodies are empty, so the hash is the SHA-256 of the empty string;
- registration (`POST /v1/houses`) needs no request signature — the record is
  itself signed, and this is where a house first announces its key.

## 6. Endpoints

All responses are JSON. Errors are `{"error":{"code":"…"}}`.

### `GET /v1/meta`

```json
{
  "name": "junderground",
  "version": "0.1.0",
  "pubkey": "<switch's Ed25519 public key, base64>",
  "public_url": "https://thejunderground.example",
  "issued": 1760000000,
  "houses": 12,
  "max_skew": 300,
  "features": ["signed-records", "room-grants", "turn-credentials"],
  "turn": {"urls": ["turn:turn.thejunderground.example:3478"], "ttl": 600}
}
```

Clients pin the `pubkey` (or the `public_url`) and verify grants with it.

### `POST /v1/houses`

Body: a `register` record. `201` on acceptance, `200` with
`{"unchanged":true}` if the exact signature is already stored.

```json
{"ok": true, "handle": "alpha", "seq": 1}
```

### `POST /v1/houses/:handle/records`

Signed request. Body: a `route`, `rotate` or `tombstone` record whose `handle`
matches the path and whose signer is the requester.

### `GET /v1/houses/:handle`

The latest record. `410` when tombstoned, `404` when unknown or private to you.

### `GET /v1/houses/:handle/records?since=1`

`{"handle":"alpha","records":[ … ]}`, oldest first. `since` is exclusive.

### `GET /v1/directory?since=0&limit=100`

A public feed for mirrors and caches: records in acceptance order, `limit`
capped at 500. Non-public records are filtered out.

### `POST /v1/mirror`

Unauthenticated in v1; every record is verified on its own. Intended for
another junderground, and to sit behind a peer allowlist at the proxy.

```json
{"records": [ … ]}
```

```json
{"results":[{"handle":"alpha","result":"ok"}]}
```

A record that is already stored reports `unchanged`; a divergent chain reports
the reason and is not stored.

### `POST /v1/rooms`

Signed request. Registers or updates a room record (see §7).

### `GET /v1/rooms/:handle`

`{"handle":"alpha","rooms":[{"room":"lobby","name":"Lobby","policy":"open","max":16,"recording":"off","expires":0,"room_key":"…"}]}`

### `GET /v1/rooms/:handle/:room`

The same metadata for one room.

### `POST /v1/rooms/:handle/:room/token`

Signed request, body:

```json
{"caps": ["join", "publish_audio"], "invite": "<grant, for an invite room>"}
```

Response:

```json
{
  "grant": "JG1.eyJ…uY2x…",
  "room": "alpha/lobby",
  "subject": "alpha",
  "caps": ["join", "publish_audio"],
  "expires": 1760000900,
  "ice_servers": [
    {
      "urls": ["turn:turn.example:3478"],
      "username": "1760000600:alpha",
      "credential": "…",
      "expires": 1760000600
    }
  ]
}
```

`ice_servers` is an empty list when TURN is not configured — the normal case for
a same-house call on a tailnet.

### `POST /v1/rooms/:handle/:room/revoke`

Signed request by the room's owner:

```json
{"jti": "q2Z0m8r1oQd4xY7v", "expires": 1760000900}
```

The `jti` stops verifying immediately and is forgotten after `expires`.

## 7. Rooms

A room is a policy record signed by the owning house's key:

```json
{
  "format": "junderground-room",
  "version": 1,
  "kind": "register",
  "handle": "alpha",
  "room": "lobby",
  "name": "Lobby",
  "pubkey": "C6/pZA4LW5IVvv8581VwHcTcjnnrOdPhcs/E9NKrYOM=",
  "seq": 1,
  "issued": 1760000000,
  "policy": "invite",
  "max": 16,
  "recording": "off",
  "expires": 0,
  "sig": "…"
}
```

| Field | Values | Meaning |
| --- | --- | --- |
| `policy` | `open` | any registered house may join |
| | `house` | only the owning house |
| | `invite` | needs an `invite` grant from the owner |
| `max` | 2–256 | advisory; the SFU enforces the real limit |
| `recording` | `off` / `allow` | `record` capability is only issued to the owner when `allow` |
| `expires` | `0` or unix seconds | after this, grants are refused |

Room records use the same `seq`/`prev`/key rules as house records, and the
house must exist and not be tombstoned.

## 8. Grants and capabilities

A grant is a compact token:

```
JG1.<base64url(canonical payload)>.<base64url(Ed25519 signature)>
```

Decoded payload:

```json
{
  "format": "junderground-grant",
  "version": 1,
  "iss": "https://thejunderground.example",
  "room": "alpha/lobby",
  "room_key": "e0770913958a0ca50a1c8e372194584f0a63eb5afc286918d26aeb9c844eb461",
  "sub": "alpha",
  "caps": ["join", "publish_audio"],
  "iat": 1760000000,
  "exp": 1760000900,
  "jti": "q2Z0m8r1oQd4xY7v"
}
```

| Capability | Granted to |
| --- | --- |
| `join` | anyone admitted by the policy |
| `subscribe` | joiners (hear/see the room) |
| `publish_audio` | joiners |
| `publish_video` | joiners |
| `record` | the owner, and only when the room says `recording: "allow"` |
| `moderate` | the owner |
| `invite` | the owner (used to mint an invite grant for someone else) |

Caps are intersected with what the room allows: a request for `record` from a
guest in an open room comes back without it. `join` is mandatory; an empty
intersection is `403`.

## 9. TURN

Credentials follow coturn's `use-auth-secret` scheme:

```
username   = "<unix expiry>:<subject>"
credential = base64(HMAC-SHA1(secret, username))
```

They are minted per request and never cached. coturn is the recommended server
(`coturn` + `use-auth-secret` + `realm`), reached over UDP 3478 and TCP/TLS 5349,
with TURN-over-TLS/443 as the fallback for restrictive networks.

## 10. Errors

| Code | Status | Meaning |
| --- | --- | --- |
| `missing_auth` | 401 | a signed request without its headers |
| `stale_timestamp` / `bad_timestamp` | 401 | outside the ±300 s window |
| `replay` | 409 | nonce already used |
| `bad_signature` | 422 | signature does not verify |
| `forbidden` | 403 | wrong house for the record, or policy refuses |
| `invite_required` | 403 | invite room, no invite |
| `not_found` | 404 | unknown or private handle/room |
| `taken` | 409 | a different key tried to claim a handle |
| `retired` | 410 | tombstoned house or room |
| `expired` | 410 | room or grant past its expiry |
| `stale` / `gap` | 409 | sequence already seen, or skips a step |
| `broken_chain` | 409 | `prev` is not the current signature |
| `wrong_key` | 409 | record signed by a key that is no longer active |
| `revoked` | 409 | grant `jti` was revoked |
| `bad_*` | 422 | malformed field |

## 11. Federation

Many jundergrounds are expected. Nothing here needs consensus:

- a house may publish its chain at more than one switch (the same records);
- switches may pull each other's public feed (`GET /v1/directory?since=`) or
  push into `/v1/mirror`;
- because records are self-signed and chained, a client can verify a record
  from any switch and prefer the highest `seq` it has seen;
- a divergent chain (two different records at the same `seq`) is reported, not
  silently chosen. Resolving it is a client policy decision: highest `seq`, then
  the record whose `prev` matches the client's own last-seen signature.

## 12. Media plane (planned)

Not implemented here; the contract above is what it will consume.

- **Signaling** — a WebSocket channel per room. Join with a grant; the channel
  verifies the grant's signature, expiry, `jti` and `room_key`, then relays
  SDP/ICE. A grant is the only credential needed.
- **NAT traversal** — each participant negotiates with the room's SFU, so one
  ICE negotiation per person rather than one per pair. Direct host/STUN
  candidates are the common case; TURN is the fallback for CGNAT, symmetric NAT
  and corporate firewalls. A tailnet only helps devices in the *same* house; it
  is an optimization, not a replacement for TURN across houses.
- **SFU** — a separate process (LiveKit is the working favourite; Jitsi or Janus
  are alternatives). It validates the grant or receives a short-lived
  server-minted token from this service, and it is the thing that actually
  forwards audio. Do not put media in the Elixir node.
- **The answering bot** — a room participant, not a phone hack. When a call is
  not answered, the house's flow engine joins the room, greets, runs the
  conversation, files a transcript, and can invite the person in. On the PSTN
  side there is nothing to answer, by design.

## 13. Boundary

Out of scope, permanently:

- phone numbers (DIDs), PSTN termination, 911/emergency routing;
- recording or intercepting a cellular call;
- carrier obligations of any kind.

If a phone number is ever wanted, it is a separate product with a carrier, its
own legal review, and a SIP trunk — not a feature of this switch.

## 14. Open questions

- How a person discovers a house's handle (invite link, crest code, address book)?
- Invite distribution: the owner currently mints a grant and hands it over; a
  one-time invite URL is probably better.
- Recording consent and AI disclosure per jurisdiction, once recording exists.
- How aggressively to mirror between jundergrounds, and how to bound storage.
- SFU choice, and whether to run it in the same region as the switch.
