# The administrator's chat interface

This is the contract for the **chat app** half. The switch is headless; the
screen lives in jawnos' Chat app, which already has sections (sms, dial, list,
tickets, lora). Add one more for the house that operates a junderground:

```
Chat  →  Underground        (visible only to that house)
        ├── Houses          pending · probation · approved
        ├── Peers           other jundergrounds
        ├── Reports         what other houses flagged
        ├── Reviews         what the agent found
        └── Audit           every decision, who made it, when
```

The interface never holds a signing key it does not need. The administrator's
crest key signs admin requests; the agent can be given its own key, or run
behind a proxy that only exposes `GET` plus `POST …/review`.

## Houses

One card per house, newest first. A card answers four questions before the
administrator acts:

| Area | From | Shows |
| --- | --- | --- |
| Who | `GET /v1/admin/houses/:handle` | crest name/uuid, handle, fingerprint, routes |
| When | same | `first_seen`, last decision, `review_at` |
| Why | same + reports | status, reason, reports, last agent verdict |
| What changed | `records` | key rotations, route moves, tombstones |

A pending card offers:

- **Approve** — `status: approved`.
- **Probation** — a date picker and a reason; `status: probation`,
  `review_at`. The dialog should say what probation means: 5-minute grants,
  audio only, no recording, no invites, no new rooms.
- **Reject** — `status: rejected`.
- **Ban** — `status: banned`, the decision made at the door.

An approved or probation card offers **Suspend now** and **Ban**. Suspension is
immediate: the house's epoch moves, and every grant it already handed out stops
verifying. There is no waiting for a 15-minute token to lapse.

A stopped card offers **Reinstate** (`approved`) or **Back to probation**. A ban
is reversible by the administrator on purpose; the audit keeps both decisions.

### The probation dialog

```
Probation, not a ban.
Grants shrink to 5 minutes, audio only, no recording, no invites,
and no new rooms. Existing rooms stay open.

Review on:  [ 2026-11-02 ]     Why: [ new house, no vouches ]
```

`review_at` is advisory; nothing is promoted automatically. The date is what
puts the card at the top of the queue on that morning.

## Peers

Same card, different fields: name, `url`, peer id, fingerprint, status. The
actions are the same six states. While a peer is pending, the chat app should
show it under **Peers → Pending**, never under **Houses**.

`approved` means the peer may mirror records in. `probation` means it may read
but not push. If the peer's URL changes, its card shows the new route only after
the peer publishes `seq + 1`; the old route stays visible until then.

## Reports

Each row is `target · reporter · reason · when`. Reasons are `spam`, `abuse`,
`fraud`, `impersonation`, `illegal`, `other`; `detail` is the house's words.

One press opens the target's house card with the report in view. The agent may
read the detail; the administrator decides.

## Reviews

The agent's findings, one row per review: verdict (`clear`, `watch`, `suspend`,
`ban`), detail, evidence reference, and the status change it caused. A `watch`
is probation; `suspend` and `ban` take effect at once. Evidence is an opaque
string — a jawnos appointment id, a room transcript hash, a ticket id — so the
chat app can jump to the source when it has one.

`clear` records the review without changing anything, which is how an agent
says "I looked and found nothing" without pretending it never looked.

## Audit

`GET /v1/admin/audit?since=` for houses and `GET /v1/admin/peers/audit` for
peers. Every row: time, subject, status, operator (`admin:<key prefix>`),
reason, review date. The screen is read-only and paginated; it is the record
that makes an automated agent acceptable.

## Room pre-open sheet (the person, not the administrator)

Before a room opens, the client already has what it needs:

```
GET /v1/rooms/:handle/:room/presence
```

The room itself was reached with a **partial dial**: `event=christmas` alone is
the universal Christmas room, while `community=warwick event=rock_show
team=the_greatest_band` names one show. The sheet should show the scope, so the
person knows which room they are about to enter.

The response is a roster of handles and capabilities. The **house** — never the
switch — compares it with its people list, Box Office blacklist and hostile
marks, and draws the sheet:

```
Lobby · alpha
──────────────
[ grade ]  Person in this room is blacklisted
[ roster ] mallory   (blacklisted)
           alice     (friend)
           △ Open anyway        [ Cancel ]
```

The grading rule is `Junderground.Relationships` (see `docs/API.md` §4c). The
two hard rules for the UI:

1. `block: true` (any blacklisted subject) stops the open. "Open anyway" must be
   a deliberate second press, never the default.
2. A `hostile` grade without a blacklist is a warning, not a wall.

A room that is not open or advertised shows the roster only after the client
presents a valid grant, so a private room does not leak its guest list to
passers-by.

## Tickets and rentals

Tickets are minted by the owner and shown once as a code. The dialog has two
modes:

| Field | Private (bound) | Event (bearer) |
| --- | --- | --- |
| person | required | none |
| bind | `subject` | `bearer` |
| role | `guest` or `resident` | `guest` |
| uses | 1 | 1..100 |
| expires | clamped to the window | clamped to the window |
| meta | — | sku, seat, event |
| grants | `room:…` | `room:…`, `store:…` |
| warranty | — | terms, covers, until |

A **private** ticket is for a spouse, a parent, a guest: only that person can
spend it. An **event** ticket is a concert ticket: anyone admitted can spend one
use, which is what "sell it in the store" means. `GET …/tickets` lists what is
outstanding (subject, bind, meta, uses left, expiry) and Revoke kills a `jti`.

### Rentals

Before selling tickets, the owner reserves the room:

```
Room: lobby                 Label: The Greatest Band
Rental: 2026-12-23 18:00–22:00
Guests: 2026-12-23 18:30–21:30
Event: rock_show            Capacity: 120
Guest price: $25.00         Switch fee: $50.00
```

The editor shows the schedule (past, active, upcoming), refuses overlaps, and
marks the active window. The **guest window** is chosen inside the rental, down
to a minute. While a window is active the room is open; outside it the room is
closed to everyone but the owner. Tickets minted for the event end with the
guest window, so a ticket cannot outlive the show.

The **switch fee** comes from `GET /v1/rental_quote`; it falls with
specificity (the default is 100% for one defined construct, 50% for two, 25%
for three). The **guest price** is the renter's own, recorded as data; the store
charges it.

### Roles

The room uses the same three roles:

- **Citizen** — the person who signed the rental. Full control: passes, tickets,
  moderation, recording if allowed.
- **Resident** — band, manager, publicist, entourage. A free pass, no purchase,
  full audio/video, to the end of the rental.
- **Guest** — a paying attendee. The guest window only, audio, no recording or
  invites.

The storefront, the price, the payment and the broadcast belong to jawnos; the
chat app only asks the switch for the window and the tickets.

### Tickets, passes, and the store

> **You buy a ticket; you carry a pass.**

- **Ticket** — sold admission (price, uses, warranty, window).
- **Pass** — a role you hold (citizen, resident, guest, staff, store access).
- **Citizen ticket** (jawnos) — a delegated login to a relationship's manager;
  recommend labelling it **citizen pass**.
- **Store pass** — merch access, carried in the ticket's `grants`
  (`store:the_greatest_band`); the ticket's `warranty` records the promise.

A ticket can carry both a room grant and a store grant. The switch enforces the
room; the store verifies the rest. A warranty is inside the signed ticket, so it
is genuinely the seller's promise, not a note beside it.

## What the chat app must not do

- Do not send the people list or blacklist to the switch. Only the roster comes
  back; grading is local.
- Do not show a pending house's record to non-administrators.
- Do not put an admin key in a page or localStorage. The switch's admin
  requests are signed by jawnos on the server side, then rendered here.
- Do not treat `review_at` as an automatic approval. Nothing promotes itself.
