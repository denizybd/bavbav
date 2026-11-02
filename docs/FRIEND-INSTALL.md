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
