# junderground help

Tier-1 help for operators and integrators who run or call the switch. The switch is a signed directory plus short-lived room grants: every write is a house-signed record, registration is not admission, media never enters the Elixir process, and there is no PSTN or emergency-calling boundary. Each topic below is a standalone page with its own sources, routes, settings, stores, errors and related topics.

| id | title | summary |
| --- | --- | --- |
| `getting-started` | Getting started | Run the switch, read `/v1/meta`, and inspect the public feed and rental quote before anything is signed. |
| `identity-and-records` | Identity and records | How a house or peer proves its key, how the record chain is stored, and why registering is not admission. |
| `admission` | Admission and reports | How a house moves through pending, approved, probation and stop states, and how reports and job applications reach the house. |
| `constructs-and-dial` | Constructs, the lexicon and the dial | How the eleven social constructs, canonical slugs and the partial dial decide which room a person means. |
| `rooms-and-grants` | Rooms and grants | How a room policy becomes a short-lived grant, and what the grant can do. |
| `tickets-and-rentals` | Tickets, passes and rentals | How a house sells or gives admission for a window, and how the switch enforces the door and the ticket's life. |
| `signaling-and-sfu` | Signaling and the SFU | How a granted house joins the room's WebSocket, and when the switch hands media to an SFU. |
| `admin-and-errors` | Administrator surface and errors | The admin-signed peer routes, the error contract, and where the switch's authority stops. |

Read in this order for a first integration: getting started, identity and records, admission, constructs and the dial, rooms and grants, tickets and rentals, signaling and the SFU. Use `admin-and-errors` as the reference when a status code or an administrator route is unclear. The API contract is `docs/API.md`; the media design is `docs/SFU.md`; the administrator's screen contract is `docs/CHAT-ADMIN.md`.
