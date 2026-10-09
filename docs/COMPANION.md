# Bavbav Companion — first integration

Open with **Command 6** or Bavbav → Companion. Journal stays on Command 5.
Both are individually editable in Settings → Shortcuts. Repeating Command 6
focuses the one panel; it never toggles it closed. Closing the panel stops its
microphone, local voice, capture consent and dedicated conversation connection.
Other coding chats continue unchanged.
Opening Command 6 automatically connects the existing ChatGPT account but never
starts microphone/capture or sends a prompt. An idle child disconnect immediately
clears the connection indicator; reopening or explicitly connecting retries account
setup without retrying the previous message. Drafts are preserved.

## What is implemented

`BavbavCompanion` is a Swift library product with a native SwiftUI panel.
`CompanionConversation` and `CompanionScreenSource` are injectable host adapters.
The included Codex adapter uses BavbavCore's installed app-server resolver and
existing ChatGPT login. It never reads/copies OAuth tokens, browser cookies, API
keys or the original Companion's Keychain entries. An API-key account is rejected;
API-key environment variables are removed from this child process only.

This is **macOS speech recognition → text → Codex → macOS speech synthesis**,
not built-in ChatGPT Voice, not realtime audio inference. The native panel states
this distinction. Turkish recognition uses `tr-TR`; if on-device Turkish is
unavailable, sending audio to Apple's speech service requires the separate
unchecked opt-in. **Sesli sohbeti başlat** explicitly starts automatic turn-taking:
recognized speech ends after about 1.35 seconds of quiet (audio energy prevents
cutting a continuing phrase), its final text is sent once to the existing account,
the real completed reply is synthesized, and only natural playback completion
reopens the microphone. Actual correlated response deltas appear while the model
works; a partial response is not treated as completed or spoken as a fake answer.
The microphone is closed while waiting for/speaking the reply. A typed/manual
draft is kept separate and never silently submitted by voice mode. Fifteen seconds
without recognized speech pauses the session; each recognition is bounded to55s.
**Konuşmayı bitir · yanıtla** can finish a turn immediately. **Sustur**, ending
voice, or stopping reply audio prevents automatic listening from restarting.

**Yalnızca metne yaz** retains the separate review-before-Send (Command Return)
dictation mode. Finishing recognition closes the microphone immediately, then
allows up to two seconds for final text. Mute/STOP cancel immediately instead.
Errors preserve the last recognized text/draft and never automatically resubmit.
These are bounded Mac recognition/synthesis turns, not full-duplex native Voice.

The visible persistent `ChatGPTWebSession` remains available in a second tab of
the **same panel** for verifying the website's native Voice with the user's web
login. No private endpoints or token bridges are used. Only visible, main-frame
`https://chatgpt.com` microphone requests can ask for permission; camera and
background requests are denied. Switching away/closing ends capture and pauses
playback. Web availability or a rendered Voice button is not an audio-call pass.
“Sesi durdur” also invalidates pending consent, but leaves the visible web route
eligible for a fresh user-initiated microphone request. Closing/changing routes
revokes that eligibility. Application quit awaits the dedicated worker teardown.

## Sharing and stop boundaries

- Choose a **full physical display**, set the interval (3–60 seconds; default 10),
  check the visible full-screen consent and click Start. Enumeration/selection
  alone does not capture or send; startup/reconnection never restores consent.
  The visible screen-list button explicitly checks/requests macOS Screen Recording
  permission, displays retry/settings guidance if denied, and selects the sole
  connected screen automatically. Multiple screens still need an explicit choice.
  All visible windows, desktop, Dock and menu bar on that display can contain
  private information and will be shared. Extra displays are not silently added.
- A ScreenCaptureKit full-display filter (macOS 14+) captures a bounded PNG:
  at most 1280 pixels on the long edge and 6 MB. Display ID and dimensions are
  revalidated each time; removal/reconfiguration stops rather than substitutes a
  different screen. No system audio, continuous video, or Accessibility scraping.
- Each captured frame is sent to the dedicated account-backed conversation and
  its short observation appears silently in this panel. One frame/turn at a time;
  the selected interval starts after the previous response, so slow inference
  does not accumulate pending captures or upload backlogs. Manual dictation and
  busy user turns are skipped. During explicitly started voice, screen observations
  can proceed while listening; a recognized voice turn holds one bounded priority
  slot until any already-submitted observation drains. The next screen tick cannot
  overtake it. This uses the account's normal allowance, not free video.
- Only the latest preview and at most 80 lines remain in UI memory. Periodic
  `ScreenFrames` files use 0600 permissions in a 0700 directory and are removed
  after their owned request completes/fails. A crash can leave an owned transient
  file; server-side chat images already sent cannot be retracted by STOP.
- Stop sharing immediately revokes future frames and rejects late capture/reply
  callbacks. One already-uploaded response may drain silently to preserve the
  account connection. Full STOP, Q/close and application quit stop the dedicated
  worker as well. Reopen/reconnect requires fresh explicit sharing consent.
- The injectable single-window adapter remains for legacy scope tests and the
  safe diagnostic image-to-model check, not as the normal panel's sharing mode.
- Original Companion `SafetyGate`/`Geometry` sources are snapshotted unchanged in
  `CompanionSafety`. Their revocation epoch/stop semantics are reused. There is
  **no control grant, native input adapter, Logic Pro automation or broadened
  demo allowlist**. The UI says Logic Pro control is not ready.
- A lazy, dedicated read-only Codex conversation avoids taking ownership of an
  active coding chat. It disables shell/apps/hooks/agent tools in its child
  configuration. Unexpected permission/tool RPC requests close only that child.
  No global Codex settings are rewritten. Stopping/reconnecting opens a new
  Companion conversation; existing non-ephemeral conversations are not deleted.
- One request at a time; duplicate submits are rejected. Late/out-of-thread
  responses, duplicate items and completed-before-ack notifications are covered
  by checks. Failed sends preserve the draft and do not automatically retry.

## Verification, not product-complete claims

`zsh scripts/build-app.sh` runs the existing Bavbav checks plus
`BavbavCompanionChecks` with the explicit fake app-server. These prove state,
scope and protocol behavior, **not** microphone/permission/account acceptance.
The checker follows the repo's executable-check convention; the installed
Swift 6.4/Xcode Testing framework cannot compile its generated test runner with
the macOS 15.4 SDK used by this project (`Swift::SendableMetatype`).

Opt-in real-account test (consumes the account's normal allowance):

```sh
env -u BAVBAV_CODEX_BIN BAVBAV_COMPANION_LIVE_CHECK=1 \
  dist/Bavbav.app/Contents/MacOS/Bavbav
```

This sends a bounded Turkish text prompt on an ephemeral thread. If screen
permission is already granted, it opens **its own diagnostic window**, captures
only that window and asks the model for a random number visible only in its
pixels. A structured report is written to a unique temporary directory. Without
permission it records a blocked image test and captures nothing. It never
selects a private user window. Spoken-user recognition and audible playback
remain separate manual gates. A blocked or failed image gate returns a nonzero
exit status even if account messaging passed. The report keeps
`automatedGatesPassed` (account + image) separate from `productComplete` (also
requires live Turkish microphone recognition and audible-response acceptance).

Read-only permission preflight (no dialog, microphone, capture or model turn):

```sh
BAVBAV_COMPANION_PREFLIGHT_CHECK=1 dist/Bavbav.app/Contents/MacOS/Bavbav
```

Manual acceptance:

1. Open Command 6, connect and exchange a short text message.
2. Click “Türkçe sesi dene”; confirm actual sound and “Yanıt sesini durdur”.
3. Start **Sesli sohbeti başlat**, grant microphone/speech permissions yourself,
   opt into Apple speech only if needed, and say a fresh Turkish phrase. Verify
   the displayed transcript automatically sends once after quiet, a real answer
   arrives and is audibly spoken, and listening resumes only after playback.
   Stop reply audio or mute: no automatic restart must follow. Separately verify
   **Yalnızca metne yaz** still requires manual Send and preserves a typed draft.
4. Clear private screen content, select the full display, consent, start sharing
   and verify a visual detail absent from your text reaches the model. Wait for
   a second changed frame, then STOP and verify no further update arrives.
5. Verify the web tab separately using the visible login/Voice UI, if available.
   Do not present sign-in or button presence as a successful Voice session.

There is **one normal Bavbav process**, with Command 1–6 registered together.
A private kernel lease prevents duplicate interactive hosts. Repeated launch
focuses the existing app, never starts a competing account worker or hotkey set.
Diagnostics with explicit `BAVBAV_*CHECK` flags remain isolated and do not claim
that normal-app lease. A running older build is preserved, not forcibly killed;
close it safely before updating if its version predates the lease.

The former `--companion-only` spelling is a compatibility alias for the full app
with Companion visible, not a restricted second application. Launch through
LaunchServices to keep privacy permission attribution attached to the current
bundle:

```sh
/usr/bin/open /Users/deniz2/Documents/ChatGPT/bavbav/dist/Bavbav.app --args --companion
```

Executing its binary directly under an old responsible Bavbav can make TCC
check that old bundle's missing microphone/speech usage descriptions and abort
the new process. LaunchServices avoids inheriting that old responsible process;
verify attribution before requesting microphone access.

The panel shares Bavbav's real `AppPreferences` in normal mode. The appearance
setting changes background fills only: text/icons/borders remain opaque. Zero
transparency uses an opaque window with no blur/effect view; the green active
border and corner resizing are the same native components as other panels.

Sources checked on 2026-10-09: [Codex App Server](https://learn.chatgpt.com/docs/app-server)
(text/localImage input and turn completion), [ChatGPT Voice](https://learn.chatgpt.com/docs/features/voice)
(native availability, permissions and rollout dependence). Neither is evidence
that this Mac's embedded web Voice has completed a call.
