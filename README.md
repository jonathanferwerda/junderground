# junderground

A headless switch for houses that run jawnos: a **signed directory** of who a
house is and where it can be reached, plus **short-lived room grants** for
WebRTC calls between houses, communities, clubs, teams and projects.

It is a separate service. It does not run jawnos. It carries no PSTN,
emergency-calling or carrier obligations — the media it will broker is chat-room
class (house-to-house and community calls), not a telephone system.

> Status: **v0.1.1** — the directory, the record chain, administrator approval
> and probation, crest-bound identity, construct dials, room records, grants,
> revocations, TURN credentials and the HTTP API are implemented and tested
> (47 tests). The media plane (signaling, SFU, coturn deployment) is designed
> but not built. See `docs/API.md` for the contract and the boundary.

## Why it exists

Twilio's Programmable Voice bundles three jobs: signaling/directory, media, and
PSTN interconnect. This project owns the first two. The third — a phone number
and termination onto the phone network — is deliberately out of scope; a caller
on the legacy phone network cannot reach this switch, by design.

The directory is **signed, not authoritative**: every write is a house-signed
record, so a switch cannot impersonate a house, and a house can move to another
junderground by publishing the next record there. Many jundergrounds can mirror
the same records without consensus.

**A record is not an admission.** Registering creates a `pending` entry;
an administrator — or an approval agent holding an admin crest key — approves
it, may put it on probation, and can suspend or ban it. Probation is real:
short grants, audio only, no recording, no new rooms. Reports from other houses
land in the same queue.

**Crests are the identity.** The record's signing key is the crest key, and a
crest block may bind it to the crest uuid and name jawnos already knows.

**Rooms are dialled by social construct.** The eleven kinds and defaults are
copied from jawnos `gb.pl`, and the channel id is the same tuple the Mail app
uses, so a dial names the same room on both sides.

## Quick start

```sh
mix deps.get
mix test
PORT=4100 mix run --no-halt
curl -s localhost:4100/v1/meta | jq
```

The switch generates its Ed25519 identity on first boot at
`data/server.key` (0600) and advertises the public half from `/v1/meta`.

### Configuration

| Env | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4100` | HTTP port |
| `JG_DATA_DIR` | `data` | DETS files and the server key |
| `JG_PUBLIC_URL` | `http://localhost:4100` | `iss` on grants |
| `JG_GRANT_TTL` | `900` | Grant lifetime, seconds |
| `JG_ADMIN_KEYS` | empty | Comma-separated admin crest public keys |
| `JG_AUTO_APPROVE` | off | `1` approves every registration (development only) |
| `JG_TURN_URLS` | empty | Comma-separated coturn URLs |
| `JG_TURN_SECRET` | none | coturn `use-auth-secret` shared secret |
| `JG_SFU_URL` / `JG_SFU_KEY` / `JG_SFU_SECRET` | none | Reserved for the media plane |

## What works / what does not

| Piece | State |
| --- | --- |
| Canonical JSON + Ed25519 records | done |
| House registration, re-route, key rotation, tombstone | done |
| Directory lookup, history, global feed, mirroring | done |
| Signed request auth (timestamp + nonce + body hash) | done |
| Administrator approval, probation, suspension, audit log | done |
| Abuse reports and the admin/agent queue | done |
| Crest binding (crest key = signing key) | done |
| Rooms keyed by the Mail app's construct dial | done |
| Room records, admission policy, grants, revocation | done |
| Time-limited TURN credentials | done |
| TLS, rate limiting, metrics | not yet (run behind a proxy) |
| Signaling (WebSocket), SFU, coturn deployment | designed, not built |
| PSTN, DID, 911, recording of phone calls | out of scope |

## Layout

```
lib/junderground/
  canonical.ex   canonical JSON, byte-compatible with jawnos' Perl signer
  keys.ex        Ed25519 over canonical JSON
  record.ex      house record schema and chain rules
  directory.ex   append-only DETS store, feed and mirroring
  rooms.ex       room records, construct dials, grants, revocation
  constructs.ex  the eleven social constructs and the channel tuple
  admission.ex   pending / approved / probation / suspended / rejected / banned
  admin.ex       administrator (or approval agent) signed requests
  token.ex       JG1 capability tokens
  turn.ex        coturn credentials
  auth.ex        signed-request verification
  server_key.ex  the switch's own identity
  router.ex      the /v1 HTTP surface
docs/API.md      the API sketch and boundary
```

## Interop with jawnos

The signed bytes are the same convention jawnos already uses for crests
(`subs::crest_sign_record`: `JSON::PP->new->canonical(1)` over the record without
`sig`, then raw Ed25519). That is verified in both directions:

- a record signed by the Perl signer verifies here, byte for byte
  (`test/record_test.exs`);
- a record signed here verifies in Perl (run during development; see
  `docs/API.md`).

## Next

1. TLS in front of the listener and per-house rate limits.
2. Signaling: a WebSocket room channel, ICE config from the grant.
3. coturn deployment and the TURN fallback path.
4. An SFU adapter (LiveKit is the current favourite) and media tests.
5. The jawnos client: verify a record, dial by construct, join a room, and let
   the call bot be a room participant.
