# Install without Codex; choose the conversation account

Installing Bavbav does not make an AI request and does not require an available
Codex allowance. The drag-install DMG contains the signed application and human
instructions. It requires neither Python nor developer tools. A private full
build is needed for Deniz/Emir Workspace sharing; the public preview omits it.

## Update an existing Mac

1. Finish active work, then choose **Bavbav → Quit Bavbav** (Command-Q).
   Plain Q closes a panel, not the application.
2. Keep the old application as a recoverable copy. Replace Bavbav in its existing
   installation folder with the application from the DMG. The Applications link
   is convenient for `/Applications`; do not accidentally create a second copy
   if the existing app is in `~/Applications` or another folder.
3. Open the installed app, not the read-only DMG copy. Any macOS security or
   privacy decision belongs to the user; the package does not bypass it.
4. Existing projects, chats, pairing and Keychain entries live outside the app
   bundle. Do not delete their Application Support folders or create a new pair.
5. Verify the actual running version in **Workspace → Bavbav sürümleri**.

The application supports Apple Silicon and macOS 14 or later. Local AI weights
are a separate initial setup/download, not part of the small application DMG.

## Workspace startup recovery in 0.16.2 (77)

The private engine is 0.7.5. When the copied background executable cannot
start, it retries once with the exact Node executable already running the
approved app, while keeping the staged engine sources and dependencies.
This does not change macOS security settings, code signatures or pairing.
Live writer locks, missing modules and native-addon failures do not trigger
that executable retry.

Startup failures now show a specific `WS_…` code instead of assuming an old
standalone app is open. After dismissing the alert, **Hata kodunu kopyala**
copies only the version, readiness and support code; no raw logs, paths,
conversation contents or account credentials are copied.

Install the new app in the existing location, including if the previous copy
was renamed **Bavbav 2.app**. Keep only the intended copy running. A successful
local blocked-executable fixture is not proof of launch on the recipient's
Mac; first verify Command-7 opens there, then test the paired connection.

## Whose allowance is used?

Open **Bavbav → Konuşma kaynağı · Deniz / Emir / Yerel AI…** and select the
provider before sending. The selected owner's authenticated local Codex worker
performs the request; credentials are never copied to the other Mac.

For Emir to use Deniz:

- Both previously paired Bavbav apps must be open and connected.
- Deniz's Mac needs a working Codex executable and ChatGPT login, available
  allowance, and enabled account sharing.
- Emir does **not** need a remaining allowance or a working local login to
  request the available Deniz provider in this window.
- The owner label must show Deniz. If that owner is unavailable, the draft is
  kept; the application does not silently bill Emir or another provider.
- A finished real response proves that individual request, not future capacity.

This is a **separate, restricted text-conversation channel**. Normal project
chats, code edits, terminal tools, plugins and computer control are not routed
through it. Selecting Deniz here does not change the credentials used by normal
project chats. Local AI runs on the requesting Mac and uses neither cloud quota.

## Acceptance levels

The canonical full package runs isolated account routing fixtures, including
wrong-owner prevention, duplicate-send suppression and stop/revocation. Explicit
live mode makes one small request using the owner's existing account while the
simulated requester has no Codex worker. Neither check proves an actual second
Mac is installed, connected, permitted or has successfully received a response.
