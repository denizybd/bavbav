# Bavbav Companion — first integration

Open with **Command 5** or Bavbav → Companion. Journal has moved to Command 6.
Both are individually editable in Settings → Shortcuts. Repeating Command 5
focuses the one panel; it never toggles it closed. Closing the panel stops its
microphone, local voice, capture consent and dedicated conversation connection.
Other coding chats continue unchanged.

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
unchecked opt-in. Dictation lasts at most 55 seconds, can be muted/stopped, and
never auto-sends. Review text then click Send (Command Return). The microphone
is stopped while the reply is synthesized. Replies can be stopped independently.

The visible persistent `ChatGPTWebSession` remains available in a second tab of
the **same panel** for verifying the website's native Voice with the user's web
login. No private endpoints or token bridges are used. Only visible, main-frame
`https://chatgpt.com` microphone requests can ask for permission; camera and
background requests are denied. Switching away/closing ends capture and pauses
playback. Web availability or a rendered Voice button is not an audio-call pass.

## Sharing and stop boundaries

- Choose a window explicitly. Enumerating/selecting does not capture or send.
- Preview captures one bounded PNG via ScreenCaptureKit's single-window filter
  (macOS 14+), validating window ID, PID and bundle identity again. No full display,
  system audio, continuous stream or Accessibility scraping is used.
- Check “share this frame with the next message”, then Send. Consent is one-shot;
  previews expire after 60 seconds. Selection change/STOP invalidates pending
  capture callbacks; no fallback to another window is permitted.
- Preview stays in memory; only explicitly sent images are saved under
  `~/Library/Application Support/Bavbav/Companion/Attachments` (0600 files/0700
  directory). These are retained for chat history. Already sent images cannot
  be retracted by STOP.
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
remain separate manual gates regardless of this command's exit code.

Manual acceptance:

1. Open Command 5, connect and exchange a short text message.
2. Click “Türkçe sesi dene”; confirm actual sound and “Yanıt sesini durdur”.
3. Start dictation, grant microphone/speech permissions yourself, opt into Apple
   speech if needed, say a fresh Turkish phrase and verify the displayed text.
   Mute/STOP must close capture; partial text is never sent by itself.
4. Select a harmless window, preview, explicitly attach and ask about a visual
   detail absent from your prompt. Verify the actual answer, not just attachment.
5. Verify the web tab separately using the visible login/Voice UI, if available.
   Do not present sign-in or button presence as a successful Voice session.

`--companion-only` opens the real panel without registering the old coding
windows' hotkeys or restarting their workers. This is useful during an active
coding session. Normal global Command 5 needs the updated main Bavbav instance;
an old running version still owns its old Command 5 until safely restarted.

Sources checked on 2026-10-09: [Codex App Server](https://learn.chatgpt.com/docs/app-server)
(text/localImage input and turn completion), [ChatGPT Voice](https://learn.chatgpt.com/docs/features/voice)
(native availability, permissions and rollout dependence). Neither is evidence
that this Mac's embedded web Voice has completed a call.
