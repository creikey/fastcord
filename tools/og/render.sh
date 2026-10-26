#!/bin/sh
# Renders the 1200x630 link-preview image (site/og.jpg) from tools/og/card.html with headless Chrome.
set -e
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --screenshot=build/og.png "file://$PWD/tools/og/card.html"
sips -s format jpeg -s formatOptions 88 build/og.png --out site/og.jpg >/dev/null
echo site/og.jpg
