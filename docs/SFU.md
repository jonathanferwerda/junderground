# SFU design

Status: design. The switch is the control plane; media never enters the Elixir process.

## 1. When the mesh stops being enough

The reference client builds a full mesh: every house sends one stream to every
other house. Uplink per house is `(N-1) x bitrate`, and every silent listener
still costs one downlink. Planning numbers: Opus 32 kbps plus RTP/SRTP/IP is
about 60 kbps per audio stream; video is 1.5 Mbps at 720p30, 0.4 Mbps at 360p.

| Houses | Mesh audio, up and down each | One 720p publisher, per viewer |
| --- | --- | --- |
| 2 | 60 kbps | 1.5 Mbps up / 1.5 Mbps down |
| 4 | 180 kbps | 4.5 Mbps up with 3 viewers |
| 6 | 300 kbps | 7.5 Mbps up with 5 viewers |
| 8 | 420 kbps | not viable on a residential uplink |

Audio-only mesh is comfortable to four houses and tolerable to six. Pulled video
(`video` in section 4h) is the real ceiling: each pull is another encode from
the publisher, so three viewers of one camera is three times the upload.

The switch already holds both numbers that decide this, so it decides:

- Count is `Signaling.count/1` (live sockets). Presence is a heartbeat roster,
  not a media count; a listener with no microphone is still a socket.
- `sfu_threshold` (default 5): `mesh` below it, `sfu` at or above it.
- A room whose record `max` is below the threshold is never SFU.
- Over `max`, refuse the token. `max` is validated (2..256) but not enforced
  when a grant is minted; the SFU endpoint is the first enforcement point, and
  the mesh path should gain the same check.
- The mode is returned with the grant. A client that ignores `mesh` is out of
  contract; `max` is the backstop and the door still closes the room.

## 2. Recommended stack

**LiveKit** is the first adapter; **Janus** and **Jitsi** are alternatives; **coturn** stays the TURN server.

- LiveKit is one Go binary: no Phoenix, no XMPP, no JVM, no OTP release in
  this project (Bandit + Plug, Elixir 1.18/OTP 27, two hex dependencies).
- A LiveKit join token is HS256 JWT: `:crypto.mac(:hmac, :sha256, key, input)`
  plus base64url — ten lines in `Junderground.Sfu.Token`, no JOSE, no new
  dependency. Do not reuse `Canonical`: a JWT needs booleans, which the
  signed-record encoder deliberately forbids.
- LiveKit rooms are in memory and cheap; publish and subscribe grants map onto
  citizen/resident/guest.
- Janus is C with plugin configuration and no built-in room auth; it needs a
  plugin or a bearer in the URL, worse than a short JWT.
- Jitsi is Prosody + Jicofo + JVB with XMPP between them; the right pick only
  if a full browser conference UI is wanted. This switch does not ship one.
- coturn: `Turn.credentials/1` already mints `use-auth-secret` credentials, so
  TURN does not change. Keep one TURN authority. LiveKit's `rtc.turn_servers`
  gets a static `jg-sfu` account and realm for its own relay; the per-person
  credential in `ice_servers` stays short and serves the mesh and fallback.

## 3. Control-plane contract

Two new endpoints, house-signed like `POST .../token`:

```
POST /v1/rooms/:handle/:room/sfu/token   {"grant": "JG1..."}
POST /v1/rooms/:handle/:room/sfu/revoke  {"jti": "..."}      owner only
```

`/sfu/token` verifies `Auth.verify/2`, then `Rooms.verify_grant/1` (signature,
expiry, revoked `jti`, admission epoch, door), then that the grant names this
room, then `join`, then that the grant's `sub` equals the authenticated
requester. A house cannot upgrade another house's grant. Response:

```json
{"mode": "sfu", "url": "wss://sfu.example", "room": "r_9m2c...",
 "token": "<HS256 JWT>", "expires": 1760000300, "ice_servers": [...], "peers": 6}
```

`POST .../token` and the socket's `hello` gain the same `media` object
(`{"mode": "mesh"|"sfu", "reason": "..."}`) so a client knows before it opens
the socket; older clients ignore unknown fields. `/sfu/token` answers `200`
with `"mode": "mesh"` when no SFU is configured, so clients call it always.

All roles get `roomJoin: true`, `roomCreate: false`, `roomRecord: false` and
`canPublishData: false`: signaling stays on the switch, recording is out of scope.

| Grant role | Publish | Subscribe | `roomAdmin` |
| --- | --- | --- | --- |
| `citizen` | audio + video | yes | true |
| `resident` | audio + video | yes | false |
| `guest` | audio only, unless the grant was clamped with `publish_video` | yes | false |

A guest uses `canPublish: true` with `canPublishSources: ["microphone"]`; video
is added only when the grant carries `publish_video`. `subscribe` is required
for `canSubscribe`; `record` never sets `roomRecord`.

**Identity separation.** The participant identity (`sub`) is the grant's `jti`,
never the handle. The SFU room name is opaque:
`r_` + base64url(HMAC-SHA256(`sfu_secret`, `"room\0" <> room_key`))[0..15]. It
is stable for a room, identical for every house in it, not reversible and not
derived from the handle. The switch keeps the opaque-to-`handle/room` map in
`data/sfu.dets`; it never leaves the process. The SFU sees one opaque room,
grant ids and media — no handles, roles, passes, roster or relationship map.
Grading and blacklists stay in the house.

**Grants, epoch, revocation.** The JWT lives at most
`min(grant.exp, now + sfu_token_ttl)` (300 s default). LiveKit checks `exp` at
join, not during a session, so a short JWT is not a session kill. Revocation
has two paths: the owner's `.../sfu/revoke` calls `RemoveParticipant` for that
`jti` (best effort), and `Sfu.Reconciler` re-verifies connected identities
every 30 seconds against the grant, epoch and door, removing failures. Say so
in the API docs: a stop closes the WS within 15 s, an SFU participant in ~30.
The SFU never gets the JG grant: it cannot verify Ed25519 or learn capability meaning.

## 4. Deployment shape

| Process | Ports | Notes |
| --- | --- | --- |
| switch (Bandit) | 4100/tcp, private | behind the TLS proxy |
| TLS proxy | 443/tcp | `/v1/*` to the switch, `wss://sfu.*` to LiveKit |
| LiveKit | 7880/tcp (HTTP/WS), 7881/tcp (ICE/TCP), 50000-60000/udp | one binary; external IP and the UDP range must be reachable |
| coturn | 3478/udp+tcp, 5349/tcp+udp (TLS) | 443 TLS fallback needs its own address if the proxy owns 443 |

Environment, read in `config/runtime.exs`:

| Key | Default | Meaning |
| --- | --- | --- |
| `JG_SFU_URL` | unset | Public `wss://` base; unset means no SFU |
| `JG_SFU_KEY` | unset | LiveKit API key, equals `iss` in the JWT |
| `JG_SFU_SECRET` | unset | LiveKit API secret, 32+ bytes; also names the opaque room |
| `JG_SFU_THRESHOLD` | `5` | Room size at which the mode becomes `sfu` |
| `JG_SFU_TOKEN_TTL` | `300` | JWT lifetime ceiling, seconds |
| `JG_TURN_URLS` / `JG_TURN_SECRET` | unset | unchanged; coturn REST credentials |

`livekit.yaml` repeats the pair as `keys: {<JG_SFU_KEY>: <JG_SFU_SECRET>}`.
Rotate both sides together; tokens minted under the old secret stop working at
their five-minute expiry.

Health: `Junderground.Sfu.Health` probes `GET /` on the LiveKit HTTP port every
30 seconds with a one-second timeout, via `:httpc` (`:inets` and `:ssl`, both
stdlib). Three failures mark it unavailable; the cached answer means a token
request never blocks on a probe.
`GET /v1/meta` then carries:

```json
"sfu": {"available": true, "adapter": "livekit", "url": "wss://sfu.example",
        "threshold": 5, "token_ttl": 300}
```

and adds `"sfu"` to `features` only while it is available. Nothing else in
`/v1/meta` changes. One SFU per switch; a shared one still needs a per-switch
API key, and the opaque map stays local.

## 5. Failure and fallback

| Situation | Switch | Client |
| --- | --- | --- |
| SFU unset or unhealthy, room below `max` | `200`, `mode: mesh`, `ice_servers` | mesh; a banner only if over the comfortable size |
| SFU unhealthy, room at or over the size where mesh collapses | `503 sfu_unavailable`, `Retry-After: 30` | "media unavailable, retrying"; no silent bad mesh |
| TURN unset (tailnet) | `ice_servers: []` | direct host candidates only; same house/tailnet works, cross-house NAT fails. Say "direct only", not "error" |
| SFU dies mid-call | signaling WS unaffected | LiveKit drops the participant; client re-requests a token and gets `sfu` or `mesh` |
| Switch dies | existing SFU sessions keep talking | no new tokens or revocations; the JWT ceiling and LiveKit timeouts bound it |
| Grant expires or is revoked | WS closes in 15 s; reconciler removes the participant in 30 s | rejoin is refused at the switch |
| coturn down, SFU up | not probed in v1 | SFU relay still works if its own TURN entry is valid; mesh across houses fails |

An SFU restart is a media gap, not a signaling outage: the control plane is not
in the media path.

## 6. Implementation plan

1. `config/config.exs`, `config/runtime.exs`: add `sfu_threshold: 5` and
   `sfu_token_ttl: 300` with their `JG_SFU_*` reads; the existing keys stay.
2. `lib/junderground/sfu.ex`: pure functions `available?/0`, `enabled?/0`,
   `mode/2`, `opaque_room/1`. No process.
3. `lib/junderground/sfu/token.ex`: HS256 JWT with `iss`, `sub` (grant `jti`),
   `nbf`, `exp`, `video`, using the mapping from section 3.
4. `lib/junderground/sfu/health.ex`: the 30-second probe with an injectable
   probe function for tests; start it in `lib/junderground/application.ex`.
5. `lib/junderground/router.ex`: the two routes and the `sfu` block in
   `/v1/meta`. `lib/junderground/rooms.ex`: attach `media` to the grant
   response. `lib/junderground/signaling/socket.ex`: add `media` to `hello`.
6. `lib/junderground/sfu/client.ex` and a best-effort hook in `Rooms.revoke`:
   `RemoveParticipant` over HTTPS (`:httpc`), transport injectable.
7. `lib/junderground/sfu/reconciler.ex` and the local opaque map in
   `data/sfu.dets`: a 30-second sweep of connected identities.
8. Docs after the code: `docs/API.md` (media object in 4h, a new 4i, section
   12), README's table and env list.

Tests: `test/sfu_test.exs` for the mode threshold, opaque-room stability and
non-reversibility, JWT claims with an independent HMAC check, the capability
mapping for each role, and the TTL clamp against the grant's `exp`.
`test/sfu_http_test.exs` for the signed request, wrong-subject refusal, a
revoked grant, the room `max`, the `503` over the cap with no SFU, and
`/v1/meta`. Extend `test/signaling_test.exs` for `hello.media`. Follow its
setup (Bandit on a free port); DETS tests are `async: false`; no real SFU or
coturn in tests.

Not in scope: PSTN, DIDs, 911 and carrier obligations; recording, consent and
disclosure (the JWT says `roomRecord: false`); billing and charging (the switch
quotes fees, never charges); E2EE and insertable streams; SFU cascades; the
answering bot; SIP.

Media is chat-room class. SRTP terminates at the SFU, so an SFU call is not
end-to-end encrypted; do not describe it as such.
