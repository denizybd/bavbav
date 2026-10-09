# Companion acceptance checkpoint — 2026-10-09

First integration: Bavbav 0.10.0 (53). **Not end-to-end complete.**

| Gate | Observed evidence | Status |
| --- | --- | --- |
| Existing ChatGPT account → real reply | Opt-in ephemeral Codex turn returned the requested `MERHABA BAVBAV`; no separate API key | Passed |
| Native panel | Actual NSWindow reported visible/key, normal level (0); its own native rendering was inspected | Opened; not a microphone/capture pass |
| Turkish speech availability | `trAvailable=true`, `trOnDevice=true`, `trVoice=true` from macOS | Preflight only |
| Turkish microphone recognition | Microphone and Speech authorization statuses were 0 (not determined); no user phrase recorded | Needs local permission and a spoken phrase |
| Audible response | Turkish system voice exists; no listening confirmation | Needs actual playback/stop acceptance |
| Selected window reaches model | `CGPreflightScreenCaptureAccess() == false`; test deliberately skipped capture | Blocked by Screen Recording permission |
| ChatGPT web Voice | Visible persistent session loaded `chatgpt.com`; secure context and `getUserMedia` present, queried composer/Voice controls not found | Native Voice call unverified; no token/cookie extraction |
| Companion safety/protocol | 44 assertions: stop/late replies, stale selection, explicit one-shot image consent, duplicate submits, failures, restricted worker, real wire fixture completion before ack | Passed; fake server only |
| Command 5 / calendar | Shortcut suite 1784 assertions, 325 independently configurable bindings; Companion routes to Command 5, Journal to Command 6 | Automated routing passed; old running app must restart for new global registration |
| Existing app regressions | Canonical build checks (history, connection, rich messages, images, links, preferences, resizing, scroll, performance, rename, attachments, composer, shortcuts, journal, standalone) | Passed |

The GUI automation tool returned `bootstrapTimedOut`; it was not treated as a
successful click or permission test. The first full regression run also exposed
activation opening a fixture window; diagnostic launches now suppress automatic
foreground/reopen handling, and the composer/complete suites subsequently passed.

Raw account/permission and visible-web reports remain in unique macOS temporary
directories printed by the check commands. They were not uploaded; those local
paths may expire.

Original Desktop Companion source and saved keys were not edited. The two reused
safety files matched their originals byte-for-byte. Existing Bavbav process 9985
was left running so its coding turns could continue. Only the explicitly launched
Companion preview instance is eligible for replacement during UI verification.

Remaining acceptance: grant mic/speech permissions in the native panel and test
a fresh Turkish utterance; confirm actual audible reply and stop; explicitly
select a harmless window after Screen Recording permission and verify a visual
detail in the model response. See [the runbook](COMPANION.md).
