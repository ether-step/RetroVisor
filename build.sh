#!/bin/bash
# build.sh - build this RetroVisor fork (librashader preset support) and
# install it as /Applications/RetroVisor.app, ad-hoc signed. Needs Xcode
# with its license accepted and the Metal toolchain component
# (xcodebuild -downloadComponent MetalToolchain). The stock app, if present
# and not yet moved, is kept as /Applications/RetroVisor-stock.app.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
dd=${DERIVED_DATA:-$HOME/Library/Caches/RetroVisor-build}
"$DEVELOPER_DIR/usr/bin/xcodebuild" -project RetroVisor.xcodeproj -scheme RetroVisor \
    -configuration Release -derivedDataPath "$dd" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    build | grep -E "error:|BUILD " || true
app="$dd/Build/Products/Release/RetroVisor.app"
[ -d "$app" ] || { echo "no build product"; exit 1; }
if [ -d /Applications/RetroVisor.app ] && [ ! -d /Applications/RetroVisor-stock.app ] \
   && ! grep -q RetroArchPreset /Applications/RetroVisor.app/Contents/MacOS/RetroVisor 2>/dev/null; then
    mv /Applications/RetroVisor.app /Applications/RetroVisor-stock.app
fi
pkill -x RetroVisor 2>/dev/null || true
rm -rf /Applications/RetroVisor.app
ditto "$app" /Applications/RetroVisor.app
echo "installed /Applications/RetroVisor.app ($(codesign -dv /Applications/RetroVisor.app 2>&1 | grep -o 'Signature=.*'))"
echo "macOS asks for the Screen Recording grant again after a rebuild (new signature)."
