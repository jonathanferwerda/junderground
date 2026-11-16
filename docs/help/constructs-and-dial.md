---
id: constructs-and-dial
title: Constructs, the lexicon and the dial
summary: How the eleven social constructs, canonical slugs and the partial dial decide which room a person means.
sources: lib/junderground/constructs.ex, lib/junderground/lexicon.ex, lib/junderground/rooms.ex, lib/junderground/router.ex
routes: GET /v1/constructs; GET /v1/lexicon; GET /v1/dial; POST /v1/admin/language; POST /v1/admin/lexicon
settings: language
stores: lexicon.dets
errors: not_admin; bad_lexicon; bad_language
related: getting-started; rooms-and-grants; admin-and-errors
verified: 2026-11-16
---

# Constructs, the lexicon and the dial

A dial is made of the same eleven social constructs jawnos uses in `gb.pl`: communities, clubs, teams, people, projects, institutions, governments, corporations, places, vendors and events. `GET /v1/constructs` returns the kinds and suggested values for a dial UI; the suggestions are never applied to a room. A construct value is a canonical slug, not a display name.

The dial is partial. A construct that is not named is a wildcard, not a default: `events: christmas` alone means the universal Christmas room, while a three-construct dial names one specific show. A room matches when every construct the room defines is present in the viewer's dial with the same value; the viewer may have more. An empty room scope matches every dial, which is how a house lobby is expressed. This differs from the Mail app's `mail_channel_key`, which fills missing constructs with defaults; the jawnos dial must adopt the same partial-scope rule for the two sides to name the same room.

Canonical names are a compatibility contract between switches. The shared seed is deliberately small (for example `events: christmas`, `new_year`, `halloween`) with aliases in the sixteen interface languages; `GET /v1/lexicon` serves it. A dial is canonicalized before matching, so `events=christmas`, `events=圣诞节`, `events=navidad` and the other aliases resolve to the same slug. A room may add signed aliases in its own record; an alias already mapped to another canonical is refused by first-wins ordering. `GET /v1/dial` returns the canonical dial, the administrator's display names, any value the lexicon did not know in `unknown`, and the advertised rooms of admitted houses whose scope sits inside the dial. An unknown value is returned so the house can translate it before the next dial rather than silently dropping the room.

The switch decides identity, not language. `POST /v1/admin/language` changes the language used for display names and requires an admin-signed request; it never changes a slug, so a later language change cannot split a room that already exists. `POST /v1/admin/lexicon` adds a canonical term and its aliases; the kind must be one of the eleven, the canonical and each alias are bounded strings, and the alias list is bounded. These are administrator calls, not house calls. In-room translation and display stay with the house's Guide.
