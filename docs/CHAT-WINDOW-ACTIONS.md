# Chat window actions and embedded browser

Every conversation window has a compact **⋯** menu in its header. It acts on
that window's conversation, including when another conversation is active.

## Actions

- **Yan sohbet aç** creates a persistent Codex server branch with its own ID
  and inherited conversation history, then opens it in another native window.
  The original conversation continues independently. Its draft, attachments,
  queue, goal and running turn are not moved, sent or interrupted. The branch
  inherits the source model/effort and project or standalone classification.
  It opens with writing closed. This branches the current stored history, not
  an arbitrarily selected older message.
- **Web penceresi aç** opens Bavbav's embedded browser; **⌘8** is its default
  app-local shortcut. Chat HTTP(S) links open here as well. Search terms use
  Google; addresses, Back, Forward and Reload use real WebKit navigation.
- **Bu sohbette ara** / **⌘F** searches the messages currently loaded in that
  window. Enter advances to the next matching message; it never sends an
  underlying composer draft. The result arrows navigate backwards/forwards.
  The × button closes search.
- **Sohbet adını değiştir** uses the existing persistent server rename path.
- **Sohbeti kopyala** copies the displayed conversation messages as text.
- **Komut mesajlarını göster/gizle** uses the existing per-chat command view.

The browser is an ordinary resizable macOS window, not always-on-top. **⌘L**
focuses its address field, **⌘R** reloads and **⌘[ / ⌘]** navigate history.
**Q** closes it when not typing; it remains an ordinary character inside web
inputs. Closing releases its WebKit view; reopening reconstructs it. Shortcuts
are individually configurable in settings. Chat windows still use Q to close
only while writing is closed; closing a window does not stop its work.

## Boundaries

- This is a native Bavbav feature, not a full copy of ChatGPT's product UI.
- Browser cookies use a separate named WebKit store, never the ChatGPT login
  store. No token/cookie extraction or native script-message bridge is added.
- Navigation allows HTTP(S), rejects credential-bearing and executable/custom
  scheme URLs, and keeps user-opened popup links in the same browser window.
  Camera/microphone access is denied. Downloads are not implemented and show
  an error. An explicit link context-menu action can open the default browser.
- The embedded browser is for the user's browsing; visiting a page does not
  automatically give its contents to the model or enable agent browser control.
- Search is local to loaded messages, not a full-history server search.

## Verification and release status

`BAVBAV_BROWSER_CHECK=1` exercises actual hidden native controls and WebKit
rendering. `--browser-live` additionally verifies public HTTPS loading,
Back/Forward and Reload. Optional `--browser-report PATH` and
`--browser-render PATH` retain diagnostic artifacts.

`BAVBAV_SIDE_CHAT_CHECK=1` requires `BAVBAV_CODEX_BIN` pointing at the local
`BavbavFakeCodex`. It verifies real app store/window/RPC paths against the
fixture, including history inheritance, independent windows and drafts,
standalone classification, error recovery and native search Enter handling.
It does not prove a real-account fork or a foreground mouse interaction.

The canonical packaging command remains `zsh scripts/build-app.sh`. Compilation
and focused checks are not an installed release: stable signing, packaged
checks and an installation receipt must succeed before claiming installation.

For an explicitly chosen local development update, the existing documented
`BAVBAV_ALLOW_ADHOC_SIGNING=1` path can validate and install an ad-hoc candidate.
It is not a stable privacy-permission identity. `BAVBAV_NOTIFY_RELEASE=0`
suppresses automatic publisher notification for local-only builds; the default
release automation behavior is unchanged.
