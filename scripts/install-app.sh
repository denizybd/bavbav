#!/bin/zsh
set -euo pipefail

# Installation is separate from building so a running Bavbav process is never
# moved/re-signed in place. Neither script launches the app or requests TCC.
project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Bavbav.app"

fail() {
    print -u2 -- "Bavbav installation: $*"
    exit 1
}

require_gui_stopped() {
    local running_pids
    # comm is the executable path, not user arguments or unrelated chat text.
    # Match renamed/recoverable bundles too: Previous-Bavbav.app still maps the
    # same executable. Conservatively block any .app ending in this executable
    # (including a variant) rather than risk replacing a mapped GUI bundle.
    running_pids="$(/bin/ps -axww -o pid=,comm= | /usr/bin/awk '$0 ~ /\.app\/Contents\/MacOS\/Bavbav$/ { print $1 }')"
    [[ -z "$running_pids" ]] || fail "A Bavbav app executable is still running (PID(s): ${(j:, :)${(f)running_pids}}). Quit it normally with Command-Q, then run this installer again. The candidate and installed app were left intact."
}

check_only=0
if [[ "${1:-}" == --check ]]; then
    check_only=1
    shift
fi
[[ $# -eq 1 ]] || fail "Usage: zsh scripts/install-app.sh [--check] /absolute/dist/.bavbav-build.XXXXXX/Bavbav.app"
candidate="$1"
[[ "$candidate" == /* && "$candidate" == "${candidate:A}" ]] || fail "Use an absolute candidate path without symlink components."
[[ "${candidate:t}" == Bavbav.app && "${candidate:h:h}" == "$project_dir/dist" && "${candidate:h:t}" == .bavbav-build.* ]] || fail "Candidate must be a staged Bavbav.app from this checkout's dist directory."
[[ -d "$candidate" && ! -L "$candidate" && ! -L "$project_dir/dist" && ! -L "$app_dir" ]] || fail "Candidate/install paths must not be symlinks."
[[ -d "$candidate/Contents" && -f "$candidate/Contents/Info.plist" ]] || fail "Candidate is not an app bundle."

# Resolve before any filesystem mutation, then freeze the public identity for
# verification; a stale/invalid configured certificate never falls back.
identity="$(zsh "$project_dir/scripts/sign-app.sh" --preflight)"
if [[ "$identity" != - ]]; then
    export BAVBAV_CODESIGN_IDENTITY="$identity"
fi
zsh "$project_dir/scripts/sign-app.sh" --verify "$candidate"

receipt="${candidate:h}/validated-build.plist"
[[ -f "$receipt" && ! -L "$receipt" && "$(/usr/bin/stat -f %z "$receipt")" -le 16384 ]] || fail "Missing bounded validation receipt. Use build-app.sh to run the complete packaged fixture checks."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FormatVersion' "$receipt")" == 1 && "$(/usr/libexec/PlistBuddy -c 'Print :ValidationKind' "$receipt")" == packaged-fixture-checks && "$(/usr/libexec/PlistBuddy -c 'Print :Passed' "$receipt")" == true ]] || fail "Unsupported or incomplete validation receipt."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CandidatePath' "$receipt")" == "$candidate" && "$(/usr/libexec/PlistBuddy -c 'Print :SelectedSigningIdentity' "$receipt")" == "$identity" ]] || fail "Validation receipt does not match this candidate path/signing identity."
actual_binary_sha256="$(/usr/bin/shasum -a 256 "$candidate/Contents/MacOS/Bavbav" | /usr/bin/awk '{ print $1 }')"
actual_code_directory_hash="$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2 }')"
[[ "$actual_binary_sha256" == "$(/usr/libexec/PlistBuddy -c 'Print :BinarySHA256' "$receipt")" && "$actual_code_directory_hash" == "$(/usr/libexec/PlistBuddy -c 'Print :CodeDirectoryHash' "$receipt")" ]] || fail "Candidate changed after validation (binary or signature mismatch). Rebuild and re-run checks."

source_info="$project_dir/AppResources/Info.plist"
for key in CFBundleIdentifier CFBundleExecutable CFBundlePackageType CFBundleShortVersionString CFBundleVersion; do
    expected="$(/usr/libexec/PlistBuddy -c "Print :$key" "$source_info")" || fail "Source Info.plist lacks $key."
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$candidate/Contents/Info.plist")" || fail "Candidate Info.plist lacks $key."
    [[ -n "$expected" && "$actual" == "$expected" ]] || fail "Candidate $key does not match the current source build target. Rebuild instead of installing an older candidate."
    [[ "$actual" == "$(/usr/libexec/PlistBuddy -c "Print :$key" "$receipt")" ]] || fail "Validation receipt $key does not match the candidate."
done
[[ "$actual" =~ '^[0-9]+$' ]] || fail "Build number must be a nonempty integer."
previous_app_dir="${candidate:h}/Previous-Bavbav.app"
[[ ! -e "$previous_app_dir" && ! -L "$previous_app_dir" ]] || fail "Recovery path already exists; choose a fresh staged candidate."
[[ ! -e "$app_dir" || -d "$app_dir" ]] || fail "Canonical app path is not an app directory."
require_gui_stopped

if [[ "$check_only" == 1 ]]; then
    print -r -- "Installation preflight passed: $candidate. Check-only; no app was modified or launched."
    exit 0
fi

# The last check is deliberately immediately before the first rename. No
# process is killed, and no existing recovery bundle can be overwritten.
if [[ -d "$app_dir" ]]; then
    mv "$app_dir" "$previous_app_dir"
fi
if ! mv "$candidate" "$app_dir"; then
    if [[ -d "$previous_app_dir" && ! -e "$app_dir" ]]; then
        mv "$previous_app_dir" "$app_dir"
    fi
    fail "Installation failed; the previous app was restored where possible. The staged/recovery directory was retained."
fi

print -r -- "Installed: $app_dir"
if [[ -d "$previous_app_dir" ]]; then
    print -r -- "Recoverable previous app: $previous_app_dir"
fi
print -r -- "Launch normally with: open \"$app_dir\""
