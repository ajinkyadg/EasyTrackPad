#!/bin/zsh
set -euo pipefail

# Regenerates Assets/AppIcon.icns from the SVG sources. Only needed when
# the artwork changes — the .icns is committed, so export-app.sh never
# depends on this script (or on Quick Look's SVG renderer) at build time.
#
# AppIcon.svg is the full-detail icon; AppIcon-small.svg drops the trails
# and chevron and enlarges the fingers, and is used for the 16/32pt slices
# where the full artwork turns to mush.

SCRIPT_DIR="${0:A:h}"
ASSETS="${SCRIPT_DIR:h}/Assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() { # svg -> 1024px png
    qlmanage -t -s 1024 -o "$WORK" "$1" >/dev/null 2>&1
    print -r -- "$WORK/${1:t}.png"
}
FULL="$(render "$ASSETS/AppIcon.svg")"
SMALL="$(render "$ASSETS/AppIcon-small.svg")"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$(( size * scale ))
        src="$FULL"; (( px <= 64 )) && src="$SMALL"
        name="icon_${size}x${size}"; (( scale == 2 )) && name="${name}@2x"
        sips -z $px $px "$src" --out "$ICONSET/$name.png" >/dev/null
    done
done

iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
print "Wrote $ASSETS/AppIcon.icns"
