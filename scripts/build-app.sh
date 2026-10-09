#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Bavbav.app"
binary="$project_dir/.build/release/Bavbav"

[[ $# -eq 0 ]] || { print -u2 -- "Usage: BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh (or omit BAVBAV_STAGE_ONLY to install after checks)"; exit 1; }
[[ "${BAVBAV_STAGE_ONLY:-0}" == 0 || "${BAVBAV_STAGE_ONLY:-0}" == 1 ]] || { print -u2 -- "BAVBAV_STAGE_ONLY must be 0 or 1."; exit 1; }
[[ ! -L "$project_dir/dist" ]] || { print -u2 -- "Refusing to build through a symlinked dist directory."; exit 1; }
# Fail before icons, compilation, or any bundle mutation if stable signing is
# not configured. Never silently fall back to ad-hoc signing for production.
signing_identity="$(zsh "$project_dir/scripts/sign-app.sh" --preflight)"
if [[ "$signing_identity" != - ]]; then
    export BAVBAV_CODESIGN_IDENTITY="$signing_identity"
fi

cd "$project_dir"
sdk_fallback="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" && -d "$sdk_fallback" ]]; then
    export SDKROOT="$sdk_fallback"
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/swiftpm-module-cache"
zsh "$project_dir/scripts/build-icons.sh"
# Keep the SDKROOT and bundle layout this packaging script uses. Swift 6.3
# changed the default engine to swiftbuild, which chooses a different SDK/layout.
swift build --build-system native --disable-sandbox -c release

# Always build/sign/check a separate candidate. The installed bundle is left
# untouched until install-app.sh verifies it and proves the GUI is stopped.
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.bavbav-build.XXXXXX")"
staged_app_dir="$staging_dir/Bavbav.app"
mkdir -p "$staged_app_dir/Contents/MacOS" "$staged_app_dir/Contents/Resources"
cp "$binary" "$staged_app_dir/Contents/MacOS/Bavbav"
cp "$project_dir/AppResources/Info.plist" "$staged_app_dir/Contents/Info.plist"
cp "$project_dir/AppResources/Bavbav-v3.icns" "$staged_app_dir/Contents/Resources/Bavbav-v3.icns"
cp "$project_dir/AppResources/BavbavIcon-v3-light.png" "$staged_app_dir/Contents/Resources/BavbavIcon-v3-light.png"
cp "$project_dir/AppResources/BavbavIcon-v3-dark.png" "$staged_app_dir/Contents/Resources/BavbavIcon-v3-dark.png"
cp -R "$project_dir/.build/release/SwiftMath_SwiftMath.bundle" "$staged_app_dir/Contents/Resources/SwiftMath_SwiftMath.bundle"
mkdir -p "$staged_app_dir/Contents/Resources/Licenses"
cp "$project_dir/Vendor/SwiftMath/LICENSE" "$staged_app_dir/Contents/Resources/Licenses/SwiftMath.txt"
cp "$project_dir/.build/checkouts/swift-markdown/LICENSE.txt" "$staged_app_dir/Contents/Resources/Licenses/swift-markdown.txt"
cp "$project_dir/.build/checkouts/swift-cmark/COPYING" "$staged_app_dir/Contents/Resources/Licenses/swift-cmark.txt"
chmod +x "$staged_app_dir/Contents/MacOS/Bavbav"
zsh "$project_dir/scripts/sign-app.sh" "$staged_app_dir"
zsh "$project_dir/scripts/check-signing-requirements.sh" "$staged_app_dir"
BAVBAV_COMPANION_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$project_dir/.build/release/BavbavCompanionChecks"
BAVBAV_COMPANION_WEB_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_COMPANION_WINDOW_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$project_dir/.build/release/BavbavChecks" --protocol-fixture
BAVBAV_CONNECTION_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_HEADLESS_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_APP_ICON_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_APP_SWITCH_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_STATUS_COUNT_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_RICH_MESSAGE_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_LINK_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_IMAGE_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_PREFERENCES_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_RESIZE_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_SCROLL_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_PERFORMANCE_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_RENAME_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_ATTACHMENT_INTAKE_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_COMPOSER_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_SHORTCUT_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_JOURNAL_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_COMMANDS_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_STANDALONE_CHECK=1 BAVBAV_CODEX_BIN="$project_dir/.build/release/BavbavFakeCodex" "$staged_app_dir/Contents/MacOS/Bavbav"

# The installer accepts only this exact tested, signed candidate. A receipt is
# written after every check succeeds, not after compilation/signing alone.
# It contains public hashes/versions only and is not live permission evidence.
receipt="$staging_dir/validated-build.plist"
binary_sha256="$(/usr/bin/shasum -a 256 "$staged_app_dir/Contents/MacOS/Bavbav" | /usr/bin/awk '{ print $1 }')"
code_directory_hash="$(/usr/bin/codesign --display --verbose=4 "$staged_app_dir" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2 }')"
[[ "$binary_sha256" =~ '^[0-9a-f]{64}$' && "$code_directory_hash" =~ '^[0-9a-f]{40}$' ]] || { print -u2 -- "Unable to bind validation receipt to candidate hashes."; exit 1; }
/usr/libexec/PlistBuddy -c 'Add :FormatVersion integer 1' "$receipt"
/usr/libexec/PlistBuddy -c 'Add :ValidationKind string packaged-fixture-checks' "$receipt"
/usr/libexec/PlistBuddy -c 'Add :Passed bool true' "$receipt"
/usr/libexec/PlistBuddy -c "Add :CandidatePath string $staged_app_dir" "$receipt"
/usr/libexec/PlistBuddy -c "Add :BinarySHA256 string $binary_sha256" "$receipt"
/usr/libexec/PlistBuddy -c "Add :CodeDirectoryHash string $code_directory_hash" "$receipt"
/usr/libexec/PlistBuddy -c "Add :SelectedSigningIdentity string $signing_identity" "$receipt"
for key in CFBundleIdentifier CFBundleExecutable CFBundlePackageType CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$staged_app_dir/Contents/Info.plist")"
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$receipt"
done

print -r -- "All packaged fixture checks passed. Candidate: $staged_app_dir"
if [[ "${BAVBAV_STAGE_ONLY:-0}" == 1 ]]; then
    print -r -- "Stage-only build: the installed app was not replaced or launched."
    print -r -- "$staged_app_dir"
else
    zsh "$project_dir/scripts/install-app.sh" "$staged_app_dir"
    print -r -- "$app_dir"
fi
