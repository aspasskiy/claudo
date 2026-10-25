#!/bin/bash
# Renders Claudo's app icon to Resources/AppIcon.png: a ball of yarn wound from session threads, two loose
# ends, the Claude spark in the corner. Needs node and rsvg-convert (brew install librsvg).
# `tools/make-icon.sh light` renders the light tile instead of the dark one.
set -euo pipefail
cd "$(dirname "$0")/.."
SVG=$(mktemp -t claudo-icon).svg
node tools/make-icon.mjs "${1:-dark}" "$SVG"
rsvg-convert -w 1024 -h 1024 "$SVG" -o Resources/AppIcon.png
rm -f "$SVG"
echo "wrote Resources/AppIcon.png"
