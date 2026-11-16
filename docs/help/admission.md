---
id: admission
title: Admission and reports
summary: How a house moves through pending, approved, probation and stop states, and how reports and job applications reach the house.
sources: lib/junderground/admission.ex, lib/junderground/applications.ex, lib/junderground/admin.ex, lib/junderground/router.ex
routes: POST /v1/reports; GET /v1/admin/queue; GET /v1/admin/houses/:handle; POST /v1/admin/houses/:handle/status; GET /v1/admin/audit; GET /v1/admin/reports; POST /v1/admin/houses/:handle/review; GET /v1/admin/reviews; POST /v1/apply/:handle; GET /v1/apply/:id; GET /v1/houses/:handle/applications; POST /v1/houses/:handle/applications/:id/status
settings: auto_approve; admin_keys
stores: admission.dets; applications.dets
errors: not_admin; not_admitted; room_closed; not_found; forbidden; rate_limited
related: identity-and-records; admin-and-errors; rooms-and-grants; tickets-and-rentals
verified: 2026-11-16
---

# Admission and reports

Admission is deliberately separate from the record chain. A house can publish a valid record and still be `pending`; an administrator decides whether it may use this switch. The six states are `pending`, `approved`, `probation`, `suspended`, `rejected` and `banned`. `approved` is normal use. `probation` is a real restriction: grants shrink to at most five minutes, capabilities drop to `join`, `subscribe` and `publish_audio`, recording and invites are unavailable, and the house cannot open a new room, though its existing rooms keep working. `suspended`, `rejected` and `banned` may not append records, create rooms or receive grants. Only `approved` and `probation` appear in lookups and on the dial.

Administrator requests are signed like house requests but name a crest key in `X-JG-Admin` instead of a handle. Only keys in `admin_keys` (from `JG_ADMIN_KEYS`) are accepted. `GET /v1/admin/queue` returns the pending and probation lists; `GET /v1/admin/houses/:handle` returns the signed record, admission entry and history that a decision needs. `POST /v1/admin/houses/:handle/status` takes `status`, `reason` and an optional `review_at`. `review_at` is advisory: it sorts the queue and nothing promotes automatically. Every decision is appended to the audit log read by `GET /v1/admin/audit`.

`POST /v1/admin/houses/:handle/review` records an agent's verdict without conflating it with a status edit. `clear` records the review and changes nothing; `watch` puts the house on probation; `suspend` and `ban` take effect at once. A stop bumps the house's admission epoch, so every grant already issued under the old epoch stops verifying immediately rather than at its natural expiry. `GET /v1/admin/reviews` lists those findings for the administrator's screen. Self-registration is auto-approved only when `auto_approve` is enabled (development) or when the crest key is itself an admin key.

Reports are house-signed and land in the same review flow. `POST /v1/reports` carries a target handle, one of `spam`, `abuse`, `fraud`, `impersonation`, `illegal` or `other`, and optional detail. A house cannot report itself. Administrators read them with `GET /v1/admin/reports` and open the target's house card from the queue.

Job applications are the one public ingress for a person with no house handle. `POST /v1/apply/:handle` stores the application and returns the applicant's private status token once; `GET /v1/apply/:id?token=` lets that person read the answer without an account. The house lists and decides over its signed rail with `GET /v1/houses/:handle/applications` and `POST /v1/houses/:handle/applications/:id/status`; only the owning house may do either. Decisions are `received`, `approved` or `declined`. Requests are limited to 20 an hour per IP and 200 an hour per house, the IP is stored only as a short hash, and an unknown or unadmitted handle answers `404` so the route does not reveal which houses exist. The switch stores the application as sent and never decides it.
