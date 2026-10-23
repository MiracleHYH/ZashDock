#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -le 1 ]] || { printf '%s\n' 'Usage: Scripts/generate-app-icons.sh [source.png]' >&2; exit 2; }
icon_source=${1:-Design/AppIcon/ZashDock-icon.png}
icon_set=Sources/ZashDock/Resources/Assets.xcassets/AppIcon.appiconset
[[ -f "$icon_source" && -f "$icon_set/Contents.json" ]] || { printf '%s\n' 'Icon source or asset catalog is missing.' >&2; exit 1; }

# Resolution conversion only. Preserve the generated artwork and transparency.
for icon_points in 16 32 128 256 512; do
  for icon_scale in 1 2; do
    icon_pixels=$((icon_points * icon_scale))
    icon_suffix=
    if [[ "$icon_scale" == 2 ]]; then icon_suffix=@2x; fi
    sips -s format png --resampleHeightWidth "$icon_pixels" "$icon_pixels" "$icon_source" \
      --out "$icon_set/icon_${icon_points}x${icon_points}${icon_suffix}.png" > /dev/null
  done
done
printf '%s\n' "Generated 10 macOS AppIcon images in $icon_set"
