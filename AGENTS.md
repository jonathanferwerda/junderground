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

## Boundary

No PSTN, no DIDs, no 911, no carrier obligations. Media is chat-room class.
If a phone number is ever added, that is a separate, legally reviewed product.
