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

## Full-screen sharing and one application — 0.10.1 (56)

The user's latest instruction supersedes the window-only sharing scope. The
native panel now explicitly starts **full-display snapshots**, including visible
apps, desktop, Dock and menu bar. Default interval is 10 seconds, adjustable
3–60. It waits for each account-backed observation before the next interval,
skips busy/dictation periods and never builds a capture or turn queue. Periodic
observations are silent and preserve the user's message draft. Consent is not
restored on startup/reconnect. Temporary frame files are private and deleted
after each completed/failed request; only one latest preview and 80 lines remain
in UI memory. STOP/close fence late frames and replies. A share-only STOP allows
one already-uploaded reply to drain without disconnecting the account.

Account connection now starts automatically when the visible native panel opens,
but no prompt, microphone or frame is started by that connection. Idle child
termination immediately clears the connected indicator; reconnection is explicit
through reopening/connecting, with no message retry. Native screenshot cancellation
before submission does not unnecessarily disconnect a healthy account.

The isolated Companion launch mode has been removed: its legacy spelling opens
the full application. A secure kernel lease and an older-running-app check prevent
competing interactive hosts, workers and hotkey registrations. All six global
shortcuts register together. The native macOS Windows menu also exposes all six,
fixing local AppKit key-equivalent events from the Companion text editor without
routing its ordinary text/Q/Space into another coding panel.

Canonical build/signature and complete existing regressions passed. Added/updated
checks passed: 346 Companion fixture assertions; 34 isolated single-instance
checks; 1804 shortcut assertions; 19 scoped-hotkey, 6 web media and 54 native theme
checks. These remain fixture/native-render evidence, not live microphone/image
acceptance. Opaque/translucent foreground and full zero-transparency reset were
inspected in the actual native cached render.

Live follow-through on this Mac:

- The old preview was quit through its normal application Quit action, not a
  broad process kill. Its unsent draft was restored to the full application.
- The final normal application launched through LaunchServices, PID21598/parent1.
  It registered shortcuts1–6 and visibly connected the existing account. No screen
  sharing or microphone was started. Existing projects/chats/keys were not removed.
- Real keyboard commands1–6 opened their intended native panels in that same PID:
  Projects, Recent Signals, standalone Chat, Write Control, Journal, Companion.
  Q on panels1–5 returned to Companion; repeated Command1 kept Projects open.
- A deliberately duplicated LaunchServices launch with legacy `--companion-only`
  logged reuse of PID21598 and exited before account/hotkey initialization. Only
  one interactive Bavbav process remained, with its normal owned app-server children.
- The real-account ephemeral test again received `MERHABA BAVBAV` (08:01:24UTC).
  Screen permission remained false; microphone/speech remained0. Its structured
  report correctly kept `automatedGatesPassed=false`, `productComplete=false`
  and recorded no capture attempt. Full-display periodic image-to-model, a fresh
  spoken Turkish phrase and an audible reply are still unverified until the user
  grants local permissions and explicitly starts those features.

Account report: unique local temporary acceptance directory
`bavbav-companion-acceptance-0F4D9EAC-25C8-4CD6-8AAC-21257A081A9D`.
Final launch and duplicate logs: `bavbav-final-launch.uzhBTq` and
`bavbav-final-duplicate.gppIti` in the macOS temporary directory. Paths may expire;
no private account storage or screen contents were copied into this report.
