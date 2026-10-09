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

## Reliability follow-up — 0.10.1 (54–55)

The follow-up corrects four independently identified lifecycle defects:

- Cancelling an accepted send interrupts its turn; cancellation before its ID
  is known closes only the dedicated child. A slot is retained until cleanup.
  An ambiguous failed start cannot leak a writer into the next send. The draft
  is retained and a disconnected panel offers reconnection, without retrying.
- The start acknowledgement selects the turn ID; same-thread stale turns cannot
  claim that correlation. Pre-ack turn buffering is bounded to 16 turn IDs.
- Ending dictation closes actual audio input immediately but allows a bounded
  two-second final-text flush. Mute/STOP remain immediate revocations. Manual
  draft edits are not overwritten during preparation/finalization.
- Web media STOP invalidates pending consent without disabling future explicit
  Voice attempts in the still-visible route. Closing/changing routes does revoke
  eligibility. Application termination awaits the same dedicated shutdown task.

Acceptance reporting also now returns a nonzero status for a blocked/failed
image gate, even if account messaging passed. Account/image automated results
are separate from product completion, which additionally requires real Turkish
microphone recognition and audible response acceptance. The preflight command
requests no permissions, opens no microphone and attempts no capture.

Build 54 passed 137 Companion fixture assertions, 6 web consent-state assertions,
and the full canonical build/regression/signature checks. A fresh real account
turn again returned `MERHABA BAVBAV`. Screen permission remained false and
microphone/speech authorization remained 0; no image was captured. The live
report correctly returned exit 1 with `automatedGatesPassed=false` and
`productComplete=false`, rather than masking those unverified gates.

### User override: Command 6 and Bavbav appearance

The latest mapping supersedes the initial mapping above: **Journal remains
Command 5; Companion is Command 6**. The panel now shares Bavbav's actual palette,
background-only transparency preference, green focus outline and corner-resize
container. The user's saved 40% transparency was preserved, not overwritten.

The prior binary-launched preview (build 53, PID 16721) crashed when a microphone
permission was requested. The crash and TCC unified log identify the cause:
responsible process 9985 was still the old build 52, whose retained bundle lacked
`NSMicrophoneUsageDescription`/`NSSpeechRecognitionUsageDescription`. TCC resolved
that old responsible bundle, found a null usage description, and aborted the
requesting preview despite its new bundle containing both strings. This was not
reported as a successful permission test. Launch the current preview through
LaunchServices (`open -n ... --args --companion-only`) and verify its fresh TCC
attribution before requesting microphone access. Keep the old coding process
untouched until a safe normal-app restart is explicitly agreed.

Build 55 canonical package passed: 137 Companion assertions, 6 web consent-state
assertions, 19 scoped-hotkey configuration assertions, 54 hidden native theme
checks, and the existing complete app suite (including 1784 shortcut and 81
journal checks). Native cached renders at 0%, 100% and reset-to-0 were inspected:
the zero-transparency sample was entirely opaque, while 100% kept opaque green
foreground with clear background pixels. Bundle signature verification passed.

The real build55 panel was opened through LaunchServices, PID18276/parent1,
visible/key at normal level0. Carbon registered **only Command6** successfully;
the old original9985 stayed alive, retaining its existing coding windows/keys.
The user's saved40% transparency remained40. TCC microphone/speech preflight
logs now identify only the current requester18276 and current `dist/Bavbav.app`,
with no inherited old responsible9985 override. This confirms the launch-chain
fix, not microphone use: microphone/speech remained0 and screen accessfalse.
Actual spoken phrase, audible reply/stop, selected-window-to-model and embedded
ChatGPT native Voice still require separate live acceptance.
