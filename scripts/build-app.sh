#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Bavbav.app"
binary="$project_dir/.build/release/Bavbav"

cd "$project_dir"
sdk_fallback="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" && -d "$sdk_fallback" ]]; then
    export SDKROOT="$sdk_fallback"
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/swiftpm-module-cache"
zsh "$project_dir/scripts/build-icons.sh"
swift build --disable-sandbox -c release

# Do not overwrite a mapped executable or re-sign the currently running bundle.
# Keep the previous bundle intact so existing chats can finish in that process.
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.bavbav-build.XXXXXX")"
staged_app_dir="$staging_dir/Bavbav.app"
previous_app_dir="$staging_dir/Previous-Bavbav.app"
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
codesign --force --deep --sign - "$staged_app_dir" >/dev/null
codesign --verify --deep --strict "$staged_app_dir"
BAVBAV_APP_ICON_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_APP_SWITCH_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_RICH_MESSAGE_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
BAVBAV_LINK_CHECK=1 "$staged_app_dir/Contents/MacOS/Bavbav"
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

if [[ -e "$app_dir" ]]; then
    mv "$app_dir" "$previous_app_dir"
fi
if ! mv "$staged_app_dir" "$app_dir"; then
    if [[ -d "$previous_app_dir" && ! -e "$app_dir" ]]; then
        mv "$previous_app_dir" "$app_dir"
    fi
    exit 1
fi

echo "$app_dir"
