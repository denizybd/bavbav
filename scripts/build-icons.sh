#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
resources_dir="$project_dir/AppResources"
iconset_dir="$resources_dir/Bavbav-v3.iconset"

# Source artwork is versioned alongside the app. Packaging only masks/resamples it;
# no generation service or appearance setting is involved in a build.
swift "$project_dir/scripts/PrepareAppIcons.swift" "$resources_dir"
iconutil --convert icns --output "$resources_dir/Bavbav-v3.icns" "$iconset_dir"
