# junderground checkpoint

## Agent: DeepSeek V4.1 Flash (Zed) — 2026-10-26 22:45 UTC

Goal: v0.1.2 — peer onboarding, instant suspension, presence + relationship
grading, tickets and private rooms, agent review API.

Done (all committed unless this file says otherwise):
- `peers.ex`, `presence.ex`, `relationships.ex` added.
- `admission.ex`: `revoked_before`, `epoch` (bumped on every stop), `review/5`,
  `reviews/2`; `watch`→probation, `suspend`→suspended, `ban`→banned.
- `rooms.ex`: policies `direct`/`ticket`, `members`, ticket issue/list/consume,
  epoch-aware grant verification.
- `router.ex`: `/v1/peers`, `/v1/peers/:id`, admin peers/queue/audit, presence
  join/leave/roster, tickets, reviews; `/v1/mirror` now needs an approved peer.
- `docs/CHAT-ADMIN.md` is the chat-app UI contract; `docs/API.md` covers every
  endpoint; 66 tests pass.

Next:
1. Commit v0.1.2 (this file goes with it).
2. Signaling channel (WebSocket, grant-in / SDP+ICE out) and SFU adapter.
3. jawnos client: verify record, dial by construct, grade roster, join.
4. Chat app Underground section per `docs/CHAT-ADMIN.md`.
