#!/bin/zsh
set -euo pipefail
umask 077

# Produce a friend-facing drag installer. This is packaging only: no app is
# launched, no installed copy or account data is changed, and no trust or
# Gatekeeper setting is modified. Invoke with zsh, not bash.
project_dir="${0:A:h:h}"
instructions="$project_dir/Resources/Installer/KURULUM.txt"
candidate=""
output_dir=""
work_dir=""
mount_dir=""
mount_attempted=0

fail() {
    print -u2 -- "Bavbav drag installer: $*"
    exit 1
}

cleanup() {
    local cleanup_code=$?
    trap - EXIT HUP INT TERM
    if (( mount_attempted )); then
        if /usr/bin/hdiutil detach "$mount_dir" >/dev/null 2>&1; then
            mount_attempted=0
        else
            print -u2 -- "The owned test image could not be detached normally. No force detach or deletion was attempted. Retained: $work_dir"
            return $cleanup_code
        fi
    fi
    # Only the private, mktemp-created directory is ever removed. An image
    # which could still be mounted is deliberately retained above.
    if [[ -n "$work_dir" && "$work_dir" == */bavbav-drag-installer.* && -d "$work_dir" && ! -L "$work_dir" ]]; then
        /bin/rm -rf -- "$work_dir"
    fi
    return $cleanup_code
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || fail "--app needs an absolute Bavbav.app path."
            [[ -z "$candidate" ]] || fail "--app may be given only once."
            candidate="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || fail "--output needs an absolute, new output directory."
            [[ -z "$output_dir" ]] || fail "--output may be given only once."
            output_dir="$2"
            shift 2
            ;;
        *) fail "Usage: zsh scripts/package-drag-installer.sh --app /absolute/Bavbav.app --output /absolute/new-directory" ;;
    esac
done

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail "Disk-image validation requires macOS."
[[ -n "$candidate" && "$candidate" == /* && "$candidate" == "${candidate:A}" ]] || fail "Use an absolute app path without symlink components."
[[ -d "$candidate" && ! -L "$candidate" && "${candidate:t}" == Bavbav.app ]] || fail "Select a regular Bavbav.app directory."
[[ -n "$output_dir" && "$output_dir" == /* && "$output_dir" == "${output_dir:A}" ]] || fail "Use an absolute output path without symlink components."
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail "The output directory already exists; nothing was overwritten."
[[ "$output_dir" != "$candidate"/* ]] || fail "The output must not be inside the source app bundle."
[[ -d "${output_dir:h}" && ! -L "${output_dir:h}" && -w "${output_dir:h}" ]] || fail "The output parent must be an existing, writable directory."
[[ -f "$instructions" && ! -L "$instructions" ]] || fail "The static Turkish installation instructions are missing."

bundle_field() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

binary_sha() {
    /usr/bin/shasum -a 256 "$1/Contents/MacOS/Bavbav" | /usr/bin/awk '{ print $1 }'
}

code_hash() {
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2 }'
}

validate_app() {
    local inspected_app="$1" signature_metadata architectures
    [[ -d "$inspected_app" && ! -L "$inspected_app" ]] || fail "The app bundle must be a regular directory."
    [[ -f "$inspected_app/Contents/Info.plist" && ! -L "$inspected_app/Contents/Info.plist" ]] || fail "App Info.plist must be a regular file."
    /usr/bin/plutil -lint "$inspected_app/Contents/Info.plist" >/dev/null || fail "App Info.plist is invalid."
    [[ "$(bundle_field "$inspected_app" CFBundleIdentifier)" == dev.deniz.bavbav ]] || fail "Unexpected bundle identifier."
    [[ "$(bundle_field "$inspected_app" CFBundleExecutable)" == Bavbav ]] || fail "Unexpected bundle executable."
    [[ "$(bundle_field "$inspected_app" CFBundlePackageType)" == APPL ]] || fail "Unexpected bundle package type."
    [[ -f "$inspected_app/Contents/MacOS/Bavbav" && -x "$inspected_app/Contents/MacOS/Bavbav" && ! -L "$inspected_app/Contents/MacOS/Bavbav" ]] || fail "The app binary must be a regular executable."
    architectures="$(/usr/bin/lipo -archs "$inspected_app/Contents/MacOS/Bavbav")" || fail "The app binary is not a supported Mach-O executable."
    [[ " $architectures " == *" arm64 "* ]] || fail "An Apple Silicon app binary is required."
    /usr/bin/codesign --verify --deep --strict "$inspected_app" || fail "Strict app signature verification failed."
    signature_metadata="$(/usr/bin/codesign --display --verbose=4 "$inspected_app" 2>&1)" || fail "Unable to inspect the app signature."
    [[ "$signature_metadata" != *"Signature=adhoc"* ]] || fail "An ad-hoc development signature is not a friend release."
    print -r -- "$signature_metadata" | /usr/bin/awk '$0 == "Identifier=dev.deniz.bavbav" { found = 1 } END { exit !found }' || fail "The signed identifier is not Bavbav."
}

validate_app "$candidate"
bavbav_version="$(bundle_field "$candidate" CFBundleShortVersionString)"
bavbav_build="$(bundle_field "$candidate" CFBundleVersion)"
[[ "$bavbav_version" =~ '^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$' ]] || fail "The app version is invalid."
[[ "$bavbav_build" =~ '^[1-9][0-9]{0,6}$' ]] || fail "The app build is invalid."
(( bavbav_build <= 1000000 )) || fail "The app build exceeds the release limit."
source_binary_sha="$(binary_sha "$candidate")"
source_code_hash="$(code_hash "$candidate")"
[[ "$source_binary_sha" =~ '^[0-9a-f]{64}$' && "$source_code_hash" =~ '^[0-9a-f]{40}$' ]] || fail "Unable to bind the package to the signed app."

# mkdir is the atomic reservation: even a concurrent invocation cannot replace
# an existing delivery. A failed delivery is retained, never silently reused.
/bin/mkdir "$output_dir" || fail "Unable to reserve the new output directory."
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bavbav-drag-installer.XXXXXX")"
payload_dir="$work_dir/payload"
mount_dir="$work_dir/mounted"
/bin/mkdir "$payload_dir" "$mount_dir"
/usr/bin/ditto "$candidate" "$payload_dir/Bavbav.app"
/bin/ln -s /Applications "$payload_dir/Applications"
/usr/bin/ditto "$instructions" "$payload_dir/KURULUM.txt"
validate_app "$payload_dir/Bavbav.app"
[[ "$(binary_sha "$payload_dir/Bavbav.app")" == "$source_binary_sha" && "$(code_hash "$payload_dir/Bavbav.app")" == "$source_code_hash" ]] || fail "The staged app does not match the signed source."

image_name="Bavbav-${bavbav_version}-${bavbav_build}-macOS-AppleSilicon.dmg"
working_image="$output_dir/.${image_name%.dmg}.working.dmg"
final_image="$output_dir/$image_name"
/usr/bin/hdiutil create -quiet -format UDZO -fs HFS+ -volname "Bavbav $bavbav_version ($bavbav_build)" -srcfolder "$payload_dir" "$working_image"
/usr/bin/hdiutil imageinfo -plist "$working_image" > "$work_dir/image-info.plist"
[[ "$(/usr/bin/plutil -extract Format raw "$work_dir/image-info.plist")" == UDZO ]] || fail "The disk image is not the required compressed, read-only format."

# A fresh private mountpoint and the image just created above identify only our
# own image. No Finder window or application is opened during this check.
mount_attempted=1
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" -plist "$working_image" > "$work_dir/attach.plist"
mounted_app="$mount_dir/Bavbav.app"
validate_app "$mounted_app"
[[ "$(bundle_field "$mounted_app" CFBundleShortVersionString)" == "$bavbav_version" && "$(bundle_field "$mounted_app" CFBundleVersion)" == "$bavbav_build" ]] || fail "The mounted app version does not match."
[[ "$(binary_sha "$mounted_app")" == "$source_binary_sha" && "$(code_hash "$mounted_app")" == "$source_code_hash" ]] || fail "The mounted signed app does not match the source."
[[ -L "$mount_dir/Applications" && "$(/usr/bin/readlink "$mount_dir/Applications")" == /Applications ]] || fail "The Applications shortcut was not preserved."
/usr/bin/cmp -s "$instructions" "$mount_dir/KURULUM.txt" || fail "The mounted instructions do not match."
/usr/bin/hdiutil detach "$mount_dir" >/dev/null || fail "The owned test image could not be detached normally; no force detach was attempted."
mount_attempted=0

# Detect a source being rebuilt/re-signed while the package was being checked.
validate_app "$candidate"
[[ "$(binary_sha "$candidate")" == "$source_binary_sha" && "$(code_hash "$candidate")" == "$source_code_hash" ]] || fail "The source app changed during packaging."
/bin/mv "$working_image" "$final_image"
image_sha="$(/usr/bin/shasum -a 256 "$final_image" | /usr/bin/awk '{ print $1 }')"
[[ "$image_sha" =~ '^[0-9a-f]{64}$' ]] || fail "Unable to hash the final disk image."
print -r -- "$image_sha  $image_name" > "$output_dir/SHA256SUMS.txt"

receipt="$output_dir/validated-drag-installer.plist"
/usr/bin/plutil -create xml1 "$receipt"
/usr/bin/plutil -insert FormatVersion -integer 1 "$receipt"
/usr/bin/plutil -insert ValidationKind -string read-only-dmg-mounted-verification "$receipt"
/usr/bin/plutil -insert Passed -bool true "$receipt"
/usr/bin/plutil -insert Version -string "$bavbav_version" "$receipt"
/usr/bin/plutil -insert Build -integer "$bavbav_build" "$receipt"
/usr/bin/plutil -insert BundleIdentifier -string dev.deniz.bavbav "$receipt"
/usr/bin/plutil -insert Architecture -string arm64 "$receipt"
/usr/bin/plutil -insert DMGName -string "$image_name" "$receipt"
/usr/bin/plutil -insert DMGSHA256 -string "$image_sha" "$receipt"
/usr/bin/plutil -insert BinarySHA256 -string "$source_binary_sha" "$receipt"
/usr/bin/plutil -insert CodeDirectoryHash -string "$source_code_hash" "$receipt"
/usr/bin/plutil -insert MountedAppVerified -bool true "$receipt"
/usr/bin/plutil -insert RequiresCodexForInstallation -bool false "$receipt"
/usr/bin/plutil -insert RequiresPythonForInstallation -bool false "$receipt"
/usr/bin/plutil -insert InstalledAppChanged -bool false "$receipt"
/usr/bin/plutil -insert NotarizationVerified -bool false "$receipt"

print -r -- "Verified read-only drag installer: $final_image"
print -r -- "SHA256: $image_sha"
print -r -- "Receipt: $receipt"
print -r -- "No app was launched or installed. Notarization and recipient acceptance are not claimed."
