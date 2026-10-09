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

## Automatic Turkish voice and screen-selection repair — 0.10.2 (58)

The user's live feedback identified a real workflow gap: the original native
voice control only dictated into a draft and required manual Send. An explicit
**Sesli sohbeti başlat** now authorizes automatic recognized-text turns, without
submitting the existing typed/manual draft. Approximately1.35s of quiet ends a
recognized utterance; audio energy protects continuing phrases. The final text
submits once, actual correlated account reply deltas appear in the panel, and
the completed real answer is sent to macOS Turkish speech synthesis. Only the
current utterance's natural completion resumes listening. Initial silence is
bounded to15s and recognition to55s. Manual review-before-Send dictation remains
separate. These are Mac STT → existing account → Mac TTS turns, not full-duplex
ChatGPT native Voice or a separate paid Realtime API connection.

Mute, voice-end and reply-audio-stop revoke automatic microphone restart. Full
STOP fences old turns and closes the dedicated account transport. Voice-end
alone lets an already-submitted answer drain silently and leaves independent
screen sharing unchanged. Recognition/device/account failures preserve the last
recognized text and manual draft without automatic retries. Pending screen
observations have one writer; a recognized voice turn has one bounded priority
slot. Natural reply completion now drains any existing observation before
reopening the microphone, fixing an otherwise-stalled automatic voice loop.

The observed screen selection error on the running app was native TCC denial
("The user declined TCCs for application, window, display capture"), not an
image-upload success. The visible screen button now explicitly requests/checks
Screen Recording permission before enumeration, shows retry/Settings guidance,
and selects a sole display without capturing it. Multiple displays still require
selection. The unchecked full-screen confirmation remains separate from list,
selection and Start; no frame is captured/uploaded merely by connecting.

Canonical checks now pass670 Companion assertions, including automatic voice
chain with a speech-driver fixture, reply streaming/early-ACK/stale-item fences,
duplicate submission, natural resume, pause/STOP/error, observation priority,
resume-after-held-screen and permission-denial/retry/sole-screen cases. Existing
native theme/signature/full app checks also pass. These are not actual microphone
or full-display image-to-model acceptance.

Real runtime evidence during this update:

- Candidate57 opened through LaunchServices as the single normal app, PID23361,
  connected the existing account and registered Command1–6. No API key, cookies
  or original Companion keys were copied. Mac speakers were the actual default
  output, unmuted; microphone and screen sharing remained closed for the test.
- A bounded text-only prompt was sent through the visible Companion editor to
  the real account. The actual reply was **“Merhaba, bugün birlikte konuşabiliriz!”**,
  not the built-in demo sentence. The real native panel reported natural playback
  completion, and the user independently confirmed **“Evet, duydum”**. This proves
  real-account reply → audible Mac TTS for that candidate, not voice-input or
  automatic multi-turn acceptance.
- Fresh native preflight on candidate57 still reported microphone0/speech0 and
  screenfalse. No OS Allow button was clicked on behalf of the user, no microphone
  was opened automatically, and no full-display image was sent. The user's earlier
  report of displayed speech is not substituted for new automatic-loop evidence.

Remaining live acceptance: user-started Turkish microphone utterance → one
automatic account request → audible response → return to listening, independent
voice/audio STOP, and explicitly consented full-display changed-frame → model.
The original goal is **not product complete** on fixture/build/audio-only proof.

Final58 launch: the idle candidate was quit through its normal Cmd-Q action and
the packaged update opened through LaunchServices, PID23728/parent1. The actual
panel connected the account and logged registered shortcuts1–6 at normal window
level0. The user's selected5s interval was restored via its visible native
stepper; no draft was pending at restart. Native microphone/speech preflight
remained0 and screenfalse; automatic voice and sharing remained OFF. Final
deep/strict signature verification passed. Earlier account conversations remain
stored; no projects, chats, attachments or keys were deleted.

## Lower-latency screen-aware voice and bounded cursor — 0.10.3

Canonical build60 passed925 Companion fixture assertions, including81 desktop
control assertions, the complete existing packaged-app regression suite, and
deep/strict signature verification. A read-only final audit found and fixed a
capture-binding bug: window identity/geometry had been sampled only after the
pixels. The paired before-capture/after-capture snapshots now reject movement,
covering/reordered windows, replacement identity, changed display bounds, stale
timestamps and STOP. Session integration verifies geometry → capture → geometry;
a changed target prevents both the model send and transient image creation.

Fast screen mode keeps one authorized in-memory frame without issuing background
model requests. Explicit typed/recognized turns attach the fresh authorized image;
control turns always capture anew. Optional proactive observations remain separate
and disabled during control. Ordered terminal events replace transport polling.
Verified final-answer sentences can start bounded native synthesis before a voice
turn finishes; commentary, unknown phases, duplicate prefixes and stale generations
cannot drive streamed speech. Rewrites stop audio rather than reread a prefix.

Explicit local screen and control consent are separate. Native control is one
ordinary click per user turn with a visible click-through green cursor, fresh
frame/target/Accessibility checks and the reused STOP/epoch gate. It is not an
independent second macOS input device or unrestricted computer/Logic automation.
Successful native event dispatch deliberately does not claim application success.
No live native click has been accepted yet.

Live observations, separated from fixtures:

- The old PID23728 exited through normal Cmd-Q; LaunchServices opened updated
  Bavbav. Later user-driven restarts produced PID28530, then29396. No current
  build59 GUI crash report was found; process changes alone are not crash proof.
- PID28530 connected the existing account. Through its own empty visible editor,
  one bounded text-only test actually received **“Merhaba Deniz. Türkçe ses
  denemesi tamamlandı.”** Native measured first text2.9s, completion4.6s and actual
  AV speech start4.7s. This was not the demo button. New-engine audible acceptance
  was asked separately and remains pending. It is not microphone-loop evidence.
- The user independently reported that conversation had noticeably sped up.
  This is qualitative feedback, not a general latency benchmark.
- A subsequent no-UI permission preflight reported microphone3, speech0 and
  screentrue, without asking permission/opening audio/capturing. That diagnostic
  process is not proof of the interactive GUI's capture entitlement.
- The user later reported Screen Recording still failed despite adding Bavbav in
  Settings. The actual stored ScreenCapture allowance pins old ad-hoc CDHash
  `851b79224f35cf2c3da679bd54977c16dbc499a3`; live build59 pins
  `23b20351820289ab964566deaaec7a161c649842`, and canonical build60 pins
  `e0f637bbf5ad8337b62b53c318fe58ed91e7c6b8`. Requirement checks fail against the
  ScreenCapture allowance. Microphone/speech grants match live59; Accessibility
  also references an older identity. There are zero valid code-signing identities.
  Thus an enabled Settings entry does not establish access for the rebuilt GUI.
- Companion's voice/capture/control code is compiled into the one Bavbav GUI,
  bundle ID `dev.deniz.bavbav`. There is no external Desktop Companion dependency
  or helper permission bridge. Original Companion references are provenance only.

The exposed API key supplied in chat was not copied, used, stored in source or
added to Keychain. The account route needs no separate API key; revocation and
replacement of that disclosed key were recommended. Installed output remains
standard Yelda. The optional Chatterbox weights/dependencies were not downloaded;
no voice-quality increase is claimed without installation and listening evidence.

Following the signing diagnosis, build61's host identity guidance and
stable-certificate packaging are implemented. The complete staged development
build passed925 Companion assertions,62 hidden native theme/host-identity checks
and all existing packaged regressions; deep/strict signature validation passed.
The actual opaque native render was inspected. The staging candidate is
`dist/.bavbav-build.LW4wh2/Bavbav.app`; its completed fixture receipt binds version,
binary SHA-256,CDHash, candidate path and the explicit development signer.

Stable certificate signing is now the default; missing/malformed/nonexistent
identity preflights fail before compilation or bundle mutation. The deliberate
ad-hoc fallback was used only for this stage-only development QA. A new
read-only installer preflight validated the receipt/signature/build and correctly
refused because PID29396 was still running. It made no rename/re-sign/launch and
did not replace the canonical build60. Running/renamed/recovery app executables
are conservatively rejected; old bundles remain recoverable. Final code after
the preflight-only addition also passed zsh syntax and diff checks.

Creating/importing a local certificate and private key still needs the user's
separate approval, which has been requested but not received. Therefore stable
signing, installation of61 and its final graceful restart have not been reported
as completed. The earlier58→59 restart is distinct from that pending step.
No TCC reset/write, identifier-only requirement, trust bypass or OS Allow action
was performed. Original projects/chats/keys and recoverable previous app bundles
remain intact. Full-display image-to-model, actual microphone loop, new audible
acceptance and native click acceptance still remain distinct pending gates;
the original integration goal is not product complete.

## Combined explicit session start — 0.10.4 / build62

The native ⌘6 route now presents one **Ses + ekran + imleci başlat** action,
with the full-display/microphone/ordinary-click scope disclosed beside it.
Independent STOP remains visible outside the scrollable body. Advanced manual
controls are collapsed by default. Opening the app/panel, connecting an account
or reconnecting does not start media or authorize control. The model guidance
no longer asks for a nonexistent virtual-cursor verification switch.

An explicit start connects the existing account, obtains ordinary native
permission readiness, binds the existing selected/preferred/main physical
display, captures the first real nonempty image, enables bounded control and
starts voice. Ambiguous/missing/reconfigured display selection fails closed.
Pending Screen Recording or control permission may resume only the same still-
authorized start on focus, with read-only readiness checks and no repeat prompts.
STOP, close, disconnect, cancellation and selection changes revoke pending
intent; old callbacks cannot restart media. Later recognition/control failures
update the visible status from actual remaining media flags. No autonomous model
turn is sent at startup or on capture ticks. Native permission decisions still
belong to the user; ordinary click restrictions and independent STOP are retained.

Final stage-only packaging completed successfully with:

- **1,500 Companion assertions**, including **575 integrated startup assertions**
  and81 bounded-control assertions. These use injected account, screen, speech
  and cursor adapters; image bytes reach the injected transport, not a real model.
- **138 hidden native rendering/layout checks** at0/50/100% transparency,
  plus19 scoped-hotkey and34 single-instance checks. Start and pinned STOP have
  actual laid-out native hit targets; collapsed advanced controls are verified.
  Hidden SwiftUI accessibility trees are empty on this OS, so test-only,
  noninteractive native markers expose real layout and independently captured
  pixels establish rendered foreground. Normal runtime has no marker views.
- All existing packaged regressions, including connection, scrolling, composer,
  rename, shortcuts, image/link/rich-message rendering and performance checks.
- Deep/strict signature verification and a completed receipt binding version,
  candidate path, binary SHA-256 and CodeDirectory hash.

Candidate: `dist/.bavbav-build.IGcqbI/Bavbav.app`.
Binary SHA-256: `bef3e87abcba214c589e833236a802bc224bad1fc2dd47e00a1d947475e11d15`.
CDHash: `5011170eb87539a8d61a1ada8b986acdf01cca79`.
Native snapshots are in the temporary `bavbav-companion-theme-9D6A8EF5-DBA8-4F6D-99E0-2187779C0A85`
directory; opaque and transparent renders were inspected for readable disclosure,
foreground, Start and STOP without overlap or clipping. Diagnostic host permission
labels are not evidence of the running GUI's capture authorization.

This was an explicitly development-only ad-hoc build. The installed canonical
build60 and running PID29396 were not replaced or restarted. There are still
zero valid signing identities; creation of a persistent local signing certificate
and private key has not been authorized. No certificate/Keychain/TCC change,
permission grant, live capture/input or real-account turn occurred in this QA.
Restarting macOS is not a substitute for resolving that signer/permission binding.
Real Turkish microphone loop, full-display image arrival at the model, audible
response from this version and native click acceptance remain pending. The new
combined-start implementation is regression-tested, not a fully accepted live
product. Original projects, chats and keys remain intact.
