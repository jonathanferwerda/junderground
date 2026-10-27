# AGENTS.md — junderground

A standalone Elixir service. It is **not** part of the jawnos tree and never
runs jawnos itself. It is a signed directory + room switch for houses that use
jawnos.

## Build and test

```sh
mix deps.get
mix test
PORT=4100 mix run --no-halt
```

Elixir 1.18+ / OTP 27+. The HTTP server is Bandit (chosen over Cowboy because
cowlib's current release carries an open advisory).

## Invariants

- **The signed bytes are a cross-language contract.** `Junderground.Canonical`
  must keep producing exactly what `JSON::PP->new->canonical(1)` produces for the
  same record without `sig`. `test/record_test.exs` holds a Perl-produced
  fixture; do not change the encoder without regenerating it with
  `Crypt::PK::Ed25519`.
- Signed payloads use strings, integers, lists and maps only. No floats, no
  booleans, no null — a flag is the string `"allow"` / `"off"`.
- Every write is a record. The chain rules (`seq` steps by one, `prev` is the
  previous signature, `rotate` is signed by the old key, `tombstone` retires a
  handle) live in `Record` and `Rooms`; do not bypass them in a route.
- Grants are short-lived and revocable by `jti`; TURN credentials are shorter
  still. Nothing long-lived is handed to a client except the server's public key.
- The switch's private key is `data/server.key` (0600). Never log it, never put
  it in a record.
- Any test that touches DETS is `async: false`; the table names are global.
- **Admission is not part of the record chain.** `Directory` appends records;
  `Admission` decides whether a house may use this switch. Do not fold a status
  into a signed record — it would put the administrator inside the house's key.
- **Constructs are a compatibility contract.** The eleven kinds and defaults in
  `Constructs` must match `gb.pl`'s `%social_constructs`, and the channel string
  must stay byte-identical to `mail_channel_key` (sorted kinds, `0x1f` join).
- **A crest key is the record key.** `Record` rejects a crest whose `pubkey` is
  not the record's key; never relax that to make an import easier.
- **Administrator keys live in configuration** (`JG_ADMIN_KEYS`), never in a
  record, a log line, or the repository.
- **The relationship graph never reaches the server.** Presence returns
  handles and capabilities only. Do not add a grading endpoint or store a
  people list here; `Relationships` is the reference rule for the house.
- **Tickets are bound and spent server-side.** A ticket names one subject and
  carries a use count; never turn one into a forwardable bearer link.
- **A stop bumps the admission epoch.** Grants carry the epoch they were issued
  under, so a suspension is instant; do not weaken that to a timestamp compare.
- **Peers use their own record format** (`junderground-peer`) and their own
  signature header (`X-JG-Peer`). A peer is not a house and has no handle.
- **A blank construct is a wildcard.** `Constructs.normalize` must keep only
  defined values; do not reintroduce defaults into a room's scope. Room
  matching is `room_scope ⊆ dial`.
- **Rentals gate the room.** A room with windows is closed outside them; every
  grant and ticket is clamped to the active window's `end`. Do not let a ticket
  outlive its rental.
- **Bound vs bearer is a security boundary.** A bound ticket must be spent by
  its subject; a bearer ticket is transferable by design (the store sold it).
  Do not silently turn one into the other.
- **Roles make the caps.** A grant's role is `citizen`, `resident` or `guest`;
  a guest never exceeds the guest base caps, and a resident pass cannot mint
  tickets. Do not let a ticket's `role` change at redemption.
- **The guest window is inside the rental.** Guests are admitted only between
  `guest_start` and `guest_end`; tickets and grants clamp to it. The citizen and
  residents use the whole block.
- **The switch quotes fees; it never charges.** `Rentals.quote` reads the
  administrator's table; `fee` and `guest_price` are data for the store.
- **A feed is self-verifying.** Every room and rental in `/v1/feed` carries its
  own signature; a relay may be stale but never authoritative.
- **A citizen ticket is never stored here.** It is jawnos' delegated login, not
  a room admission; the switch only knows a room ticket and its subject.

## Boundary

No PSTN, no DIDs, no 911, no carrier obligations. Media is chat-room class.
If a phone number is ever added, that is a separate, legally reviewed product.
