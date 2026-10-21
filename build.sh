#!/bin/zsh
# Builds Spin.app with the Command Line Tools only (no Xcode needed).
#   ./build.sh            build into build/Spin.app
#   ./build.sh install    also copy to /Applications and launch it
set -euo pipefail
cd "${0:A:h}"

APP=build/Spin.app
VERSION=1.0
BUNDLE_ID=com.personal.Spin
MIN_MACOS=14.0

echo "Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    Spin/*.swift -o "$APP/Contents/MacOS/Spin"

# Fill in the Xcode build variables used by Info.plist.
sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/" \
    -e "s/\$(EXECUTABLE_NAME)/Spin/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(PRODUCT_NAME)/Spin/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/1/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    Spin/Info.plist > "$APP/Contents/Info.plist"

echo "Signing…"
codesign --force --sign - --options runtime --entitlements Spin/Spin.entitlements "$APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Spin 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Spin.app
    cp -R "$APP" /Applications/
    open /Applications/Spin.app
    echo "Installed and launched /Applications/Spin.app"
else
    echo "Built $APP — run it with: open $APP"
fi
