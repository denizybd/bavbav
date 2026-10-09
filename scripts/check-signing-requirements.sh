#!/bin/zsh
set -euo pipefail

# Read-only native codesign regression. It neither signs nor launches the app,
# touches Keychain/TCC, requests permissions, nor creates another app copy.
project_dir="${0:A:h:h}"
checks=0

fail() {
    print -u2 -- "Bavbav signing requirement check: $*"
    exit 1
}

[[ $# -eq 1 ]] || fail "Usage: zsh scripts/check-signing-requirements.sh /absolute/path/Bavbav.app"
candidate="$1"
[[ "$candidate" == /* && "$candidate" == "${candidate:A}" ]] || fail "Use an absolute app path without symlink components."
[[ -d "$candidate" && ! -L "$candidate" && "${candidate:t}" == Bavbav.app ]] || fail "A real Bavbav.app bundle is required."
[[ -f "$candidate/Contents/Info.plist" && -f "$candidate/Contents/MacOS/Bavbav" && ! -L "$candidate/Contents/MacOS/Bavbav" ]] || fail "The app metadata/executable is missing or symlinked."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" == dev.deniz.bavbav ]] || fail "Unexpected bundle identifier."
/usr/bin/codesign --verify --deep --strict "$candidate" || fail "The existing app signature is not valid."
(( checks += 1 ))

metadata="$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1)" || fail "Unable to inspect the existing signature."
cdhash="$(print -r -- "$metadata" | /usr/bin/awk -F= '$1 == "CDHash" { print $2 }')"
[[ "$cdhash" =~ '^[0-9a-f]{40}$' ]] || fail "The existing code hash is unavailable."

# Cover the production call as well as the platform syntax below. A regression
# reverting only sign-app.sh must fail even if these native probes still pass.
signing_source="$(<"$project_dir/scripts/sign-app.sh")"
[[ "$signing_source" == *'--test-requirement="=certificate leaf = H\"$identity\""'* ]] || fail "The production certificate check lost its inline '=' prefix."
[[ "$signing_source" != *'--test-requirement="certificate leaf = H'* ]] || fail "A bare production certificate requirement remains."
(( checks += 1 ))

# Matching inline text must be evaluated as a requirement, not as a filename.
/usr/bin/codesign --verify --strict --test-requirement="=cdhash H\"$cdhash\"" "$candidate" || fail "A matching inline code-hash requirement was rejected."
(( checks += 1 ))

if [[ "${cdhash[1]}" == 0 ]]; then
    wrong_cdhash="1${cdhash[2,-1]}"
else
    wrong_cdhash="0${cdhash[2,-1]}"
fi

expect_requirement_rejection() {
    local requirement="$1" result
    if result="$(LC_ALL=C /usr/bin/codesign --verify --strict --test-requirement="$requirement" "$candidate" 2>&1)"; then
        fail "A deliberately nonmatching inline requirement was accepted."
    fi
    [[ "$result" == *'code failed to satisfy specified code requirement(s)'* ]] || fail "Nonmatching inline text failed to parse instead of being evaluated: $result"
    [[ "$result" != *'invalid requirement specification'* && "$result" != *'No such file or directory'* ]] || fail "Inline text was interpreted as a filename: $result"
    (( checks += 1 ))
}

expect_requirement_rejection "=cdhash H\"$wrong_cdhash\""
expect_requirement_rejection '=certificate leaf = H"0000000000000000000000000000000000000000"'

# The original broken call must fail at parsing/file lookup, proving that these
# checks distinguish the bug from a validly parsed but nonmatching identity.
if broken_result="$(LC_ALL=C /usr/bin/codesign --verify --strict --test-requirement='certificate leaf = H"0000000000000000000000000000000000000000"' "$candidate" 2>&1)"; then
    fail "Bare certificate text unexpectedly parsed as an inline requirement."
fi
[[ "$broken_result" == *'invalid requirement specification'* ]] || fail "The bare-text negative control did not reproduce the syntax bug: $broken_result"
(( checks += 1 ))

print -r -- "SIGNING REQUIREMENT CHECKS PASSED: $checks checks; real existing signature, inline matching/rejection and bare-text negative control; no signing, launch, Keychain/TCC or permission changes"
