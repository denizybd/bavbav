#!/bin/zsh
set -euo pipefail

# Local builds must keep a certificate-bound identity across versions. An
# ad-hoc signature's cdhash changes with every build and is not a stable TCC
# identity. This helper never creates/imports/trusts a certificate or key.
project_dir="${0:A:h:h}"
identity_file="$HOME/Library/Application Support/Bavbav/Signing/code-signing-identity.txt"
bundle_identifier="dev.deniz.bavbav"

fail() {
    print -u2 -- "Bavbav signing: $*"
    exit 1
}

resolve_identity() {
    local identity="${BAVBAV_CODESIGN_IDENTITY:-}"
    if [[ -z "$identity" && -f "$identity_file" ]]; then
        [[ "$(/usr/bin/stat -f %z "$identity_file")" -le 128 ]] || fail "The public signing-identity file must contain only one SHA-1 fingerprint."
        identity="$(<"$identity_file")"
    fi

    if [[ -z "$identity" ]]; then
        if [[ "${BAVBAV_ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then
            print -u2 -- "WARNING: explicit ad-hoc DEVELOPMENT build. Screen Recording/Accessibility identity can change after every rebuild; this is not the permission-stable release path."
            print -r -- "-"
            return
        fi
        fail "No stable signing identity is configured. Set BAVBAV_CODESIGN_IDENTITY to a valid code-signing certificate SHA-1, or configure $identity_file. See docs/LOCAL-SIGNING.md. No app was modified."
    fi

    # Restrict input to a public fingerprint, not an ambiguous certificate name.
    identity="${identity:u}"
    [[ "$identity" =~ '^[0-9A-F]{40}$' ]] || fail "Signing identity must be the 40-character public SHA-1 fingerprint of a valid code-signing identity."
    local identities
    identities="$(/usr/bin/security find-identity -v -p codesigning)" || fail "Unable to inspect valid local code-signing identities."
    if ! print -r -- "$identities" | /usr/bin/awk -v wanted="$identity" '$2 == wanted { found = 1 } END { exit !found }'; then
        fail "Configured identity $identity is not a valid local code-signing identity. No fallback or app modification was performed."
    fi
    print -r -- "$identity"
}

validate_app() {
    local candidate="$1"
    [[ "$candidate" == /* && "$candidate" == "${candidate:A}" ]] || fail "Use an absolute app path without symlink components."
    [[ -d "$candidate" && ! -L "$candidate" ]] || fail "App bundle is missing or is a symlink: $candidate"
    [[ "${candidate:t}" == Bavbav.app ]] || fail "Only the Bavbav.app bundle can be handled."
    [[ -f "$candidate/Contents/Info.plist" && ! -L "$candidate/Contents/Info.plist" ]] || fail "App Info.plist must be a regular file."
    [[ -f "$candidate/Contents/MacOS/Bavbav" && -x "$candidate/Contents/MacOS/Bavbav" && ! -L "$candidate/Contents/MacOS/Bavbav" ]] || fail "App executable must be a regular executable file."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" == "$bundle_identifier" ]] || fail "Unexpected bundle identifier."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$candidate/Contents/Info.plist")" == Bavbav ]] || fail "Unexpected bundle executable."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$candidate/Contents/Info.plist")" == APPL ]] || fail "Unexpected bundle package type."
}

verify_signature() {
    local candidate="$1" identity="$2" requirements metadata
    /usr/bin/codesign --verify --deep --strict "$candidate" || fail "Strict signature verification failed."
    metadata="$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1)" || fail "Unable to read app signature."
    print -r -- "$metadata" | /usr/bin/awk -v wanted="Identifier=$bundle_identifier" '$0 == wanted { found = 1 } END { exit !found }' || fail "Signature identifier is not Bavbav's bundle identifier."
    requirements="$(/usr/bin/codesign --display --requirements - "$candidate" 2>&1)" || fail "Unable to read the designated requirement."
    if [[ "$identity" == - ]]; then
        [[ "$metadata" == *"Signature=adhoc"* ]] || fail "Explicit ad-hoc candidate verification received a different signing identity."
        return
    fi

    # codesign treats a bare requirement as a filename. The leading '=' makes
    # this an inline requirement rather than a path to a requirement file.
    /usr/bin/codesign --verify --strict --test-requirement="=certificate leaf = H\"$identity\"" "$candidate" || fail "App was not signed by the selected certificate."
    # Do not weaken the designated requirement to identifier-only to make old
    # permission records match. Keep codesign's normal certificate/anchor DR.
    [[ "$requirements" == *"designated => "* && "$requirements" == *"identifier \"$bundle_identifier\""* ]] || fail "Missing normal designated requirement."
    [[ "$requirements" == *"certificate "* || "$requirements" == *"anchor "* ]] || fail "An identifier-only designated requirement is not accepted."
    [[ "$requirements" != *"designated => cdhash "* ]] || fail "A cdhash-bound ad-hoc designated requirement is not accepted for a stable build."
}

mode="${1:-}"
case "$mode" in
    --preflight)
        [[ $# -eq 1 ]] || fail "Usage: sign-app.sh --preflight"
        resolve_identity
        ;;
    --verify)
        [[ $# -eq 2 ]] || fail "Usage: sign-app.sh --verify /absolute/path/Bavbav.app"
        identity="$(resolve_identity)"
        validate_app "$2"
        verify_signature "$2" "$identity"
        ;;
    *)
        [[ $# -eq 1 ]] || fail "Usage: sign-app.sh /absolute/staging/path/Bavbav.app | --preflight | --verify /absolute/path/Bavbav.app"
        identity="$(resolve_identity)"
        validate_app "$1"
        [[ "${1:h:h}" == "$project_dir/dist" && "${1:h:t}" == .bavbav-build.* ]] || fail "Signing is restricted to staged candidates inside this checkout's dist directory; the installed app is never re-signed."
        /usr/bin/codesign --force --deep --sign "$identity" --timestamp=none --identifier "$bundle_identifier" "$1"
        verify_signature "$1" "$identity"
        ;;
esac
