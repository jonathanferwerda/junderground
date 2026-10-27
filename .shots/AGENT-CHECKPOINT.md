# junderground checkpoint

## Agent: DeepSeek V4.1 Flash (Zed) — 2026-10-27 00:00 UTC

Done:
- v0.1.5 (c5934f4): rental door — 5-minute notice, 1-minute close, eviction
  at start; `GET /v1/rooms/:h/:r/door`; presence carries `ticketed`,
  `notify_at`, `evict_at`; older non-ticketed grants return `door_closed`.
  83 tests pass.
- jawnos (d12db7cf, pushed): access tickets renamed to passes across the UI —
  language.pl (16 languages), help.pl, Box Office, start menu, security,
  Manager.pl notifications; internal keys/DB/routes unchanged. Version 0.1.1446,
  restarted `good`; homepage renders "Pass Request".

Next:
1. Signaling channel (WebSocket: grant in, SDP/ICE out) + SFU adapter.
2. jawnos client: partial dial, roster grading, role-aware join, store pass.
3. Chat app Underground section + rental editor.
