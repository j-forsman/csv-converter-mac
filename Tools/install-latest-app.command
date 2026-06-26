#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

app_name="CSV Converter Mac.app"
project="CSV Converter Mac.xcodeproj"
scheme="CSV Converter Mac"
derived_data="/tmp/csv-converter-mac-install-derived"
built_app="$derived_data/Build/Products/Debug/$app_name"
target_app="/Applications/$app_name"

echo "Building CSV Converter Mac..."
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data" \
  build

if [[ ! -d "$built_app" ]]; then
  echo "Could not find built app: $built_app"
  exit 1
fi

echo "Closing old app if it is running..."
/usr/bin/osascript -e 'tell application "CSV Converter Mac" to quit' >/dev/null 2>&1 || true

echo "Installing latest app in /Applications..."
if [[ "$target_app" != "/Applications/CSV Converter Mac.app" ]]; then
  echo "Refusing to replace unexpected app path: $target_app"
  exit 1
fi

if [[ -e "$target_app" ]]; then
  /bin/rm -rf -- "$target_app"
fi
/bin/cp -R "$built_app" "$target_app"

echo "Starting CSV Converter Mac..."
/usr/bin/open "$target_app"

echo ""
echo "Done. Choose Downloads, or another folder, when the app asks what to watch."
echo "Use the menu bar icon to pause, change folder, scan manually, or open logs."
