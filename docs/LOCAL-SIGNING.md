# Local signing and permission-stable builds

Bavbav's Companion is compiled into the same `Bavbav.app` executable and uses
the same `dev.deniz.bavbav` bundle identity as the rest of the application. Its
Swift package target is not a separately launched permission-owning app.
Screen Recording, Accessibility, microphone, and speech authorization remain
normal macOS permissions for the actual launched application.

An ad-hoc signature identifies a build by its changing code hash. Rebuilding
the binary can therefore stop matching a previously granted permission record.
Giving two builds the same bundle name or identifier does not by itself make
their code-signing identity stable.

## Stable local identity

The production packaging path requires an existing, valid code-signing
certificate/private-key identity in the current user's Keychain. Keep that
identity across builds, keep the bundle identifier unchanged, and launch the
same installed bundle through LaunchServices. `codesign` retains its normal
certificate-bound designated requirement; the scripts do **not** replace it
with an identifier-only requirement.

Creating, importing, or trusting a local signing certificate/private key is a
separate, explicit local setup decision. These scripts do not perform it, ask
for passwords, export keys, change certificate trust, or reset/write the TCC
database. Keychain can still present its own native authorization dialog when
the selected private key is used; the user must decide that dialog.

Use `security find-identity -v -p codesigning` to inspect valid identities.
Configure the selected identity's **public, 40-character SHA-1 fingerprint**
through either:

- `BAVBAV_CODESIGN_IDENTITY`, which takes precedence; or
- `~/Library/Application Support/Bavbav/Signing/code-signing-identity.txt`,
  containing that fingerprint only.

The fingerprint is not an API key or a private signing key. A missing, expired,
untrusted, or otherwise invalid configured identity fails before compilation
or bundle mutation. An invalid explicit identity never silently falls back.

```sh
BAVBAV_CODESIGN_IDENTITY="YOUR_40_CHARACTER_PUBLIC_CERTIFICATE_SHA1" \
  zsh scripts/sign-app.sh --preflight
```

A persistent local self-signed identity can be suitable for one Mac's local
builds after the user explicitly establishes its trust. It is **not** an
Apple Developer ID signature, notarization, a generally trusted distribution,
or a bypass of any macOS privacy permission. Changing/removing the certificate
later may require granting permissions again. Previously granted ad-hoc
permissions are not promised to migrate automatically to a new stable signer.

## Build without replacing a running app

```sh
BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh
```

This resolves the signing identity, builds once, packages a fresh candidate
under `dist/.bavbav-build.XXXXXX/Bavbav.app`, signs that candidate, and runs all
packaged checks there. It leaves the canonical `dist/Bavbav.app` untouched.
Every staged directory is retained for diagnosis/recovery; nothing is
automatically deleted.

Only after all checks pass, `validated-build.plist` records the candidate's
absolute path, bundle identifier, source version/build, binary SHA-256,
CodeDirectoryHash, and public signer fingerprint. This receipt distinguishes
a fully checked candidate from a bundle that merely compiled or signed.

Quit normal Bavbav with `⌘Q` when its current work can be stopped safely, then
install the **exact candidate path printed by the build**:

```sh
zsh scripts/install-app.sh "/absolute/path/to/bavbav/dist/.bavbav-build.XXXXXX/Bavbav.app"
open "/absolute/path/to/bavbav/dist/Bavbav.app"
```

The installer verifies the signature, certificate identity, normal designated
requirement, build target, and receipt hashes before moving anything. It
refuses while any `.app/Contents/MacOS/Bavbav` GUI executable is running,
including renamed/recoverable bundles and conservatively matching variants.
It never kills a process or launches an app. The previous canonical app is
moved to `Previous-Bavbav.app` inside that candidate's staging directory, so
the baseline is recoverable. A failed install attempts to restore that bundle
and retains the staging directory.

`install-app.sh --check /absolute/candidate/Bavbav.app` performs the same
read-only validation and running-process check without installing, moving or
launching anything, even if no GUI is running.

Without `BAVBAV_STAGE_ONLY=1`, the build invokes the same installer after all
checks. If the GUI is still running, installation fails safely and the tested
candidate remains available for a later explicit install.

## Explicit development-only ad-hoc fallback

If a stable identity has not been configured, fixture-only development can
deliberately opt into:

```sh
BAVBAV_ALLOW_ADHOC_SIGNING=1 BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh
```

The warning is intentional: rebuilding changes this signing identity and can
invalidate privacy authorization. This is not the default production path
and is not a solution to recurring Screen Recording/Accessibility problems.
The installer requires the same explicit override to accept such a candidate.
It does not re-sign the installed app or convert an ad-hoc validation receipt
into a certificate-signed receipt.

## Launch and live acceptance

Launch the canonical bundle with Finder or `open /absolute/path/Bavbav.app`,
not by starting `Contents/MacOS/Bavbav` as a terminal child. The latter remains
useful for fixture diagnostics, but is not a privacy-permission acceptance
launch. Multiple copies should not be alternated when checking permission
ownership.

Successful builds, fixtures, receipts, and `codesign --verify --deep --strict`
do not prove real screen capture, microphone recognition, model receipt of an
image, audible speech, or native clicking. Grant the relevant permissions to
the actual canonical Bavbav bundle in System Settings, relaunch normally, and
exercise each real action separately. Media/control stays off until the user
starts it explicitly; local signing never grants those permissions itself.
