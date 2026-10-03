#!/usr/bin/env bash
# Takes the App Store screenshots of the in-app demo on an iOS simulator:
#   tool/store_screenshots.sh <simulator-udid> <output-dir>
# The simulator decides the size: an iPhone 11 Pro Max gives the 6.5-inch
# display's 1242x2688. Run from app/.
set -euo pipefail
udid="$1"
out="$2"
mkdir -p "$out"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
trap 'xcrun simctl status_bar "$udid" clear' EXIT

flutter test integration_test/store_screenshots_test.dart -d "$udid" \
  --dart-define=DEMO_AVAILABLE=true --dart-define=API_BASE_URL=http://127.0.0.1:9 2>&1 |
  while IFS= read -r line; do
    echo "$line"
    if [[ "$line" == *STORE_SHOT:* ]]; then
      name="${line##*STORE_SHOT:}"
      sleep 1.5
      xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null
      echo "captured $out/$name.png"
    fi
  done
