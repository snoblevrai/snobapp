#!/bin/zsh
# Compile snobapp et assemble snobapp.app.
#   ./build.sh            → build/snobapp.app
#   ./build.sh install    → copie aussi dans ~/Applications et relance l'app
# SIGN_ID="Nom du certificat" ./build.sh  → signe avec ce certificat (sinon : signature ad hoc).
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/snobapp"

APP=build/snobapp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/snobapp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# v9 : extension Finder Sync « Nouveau fichier » (clic droit du Finder), signée avant l'app.
APPEX="$APP/Contents/PlugIns/NewFile.appex"
mkdir -p "$APPEX/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos13 -module-name NewFile \
  -framework FinderSync -framework AppKit -Xlinker -e -Xlinker _NSExtensionMain \
  Extensions/NewFile/NewFileExtension.swift -o "$APPEX/Contents/MacOS/NewFile"
cp Extensions/NewFile/Info.plist "$APPEX/Contents/Info.plist"
codesign --force --sign "${SIGN_ID:--}" --entitlements Extensions/NewFile/NewFile.entitlements \
  --identifier io.github.snoblevrai.snobapp.newfile \
  -r='designated => identifier "io.github.snoblevrai.snobapp.newfile"' "$APPEX"

# Exigence désignée stable (identifiant seul) : sans elle, une signature ad hoc est liée au
# cdhash du binaire et macOS oublie l'autorisation Accessibilité à chaque recompilation.
codesign --force --sign "${SIGN_ID:--}" --identifier io.github.snoblevrai.snobapp \
  -r='designated => identifier "io.github.snoblevrai.snobapp"' "$APP"
echo "✓ $APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  pkill -x snobapp 2>/dev/null || true
  rm -rf ~/Applications/snobapp.app
  cp -R "$APP" ~/Applications/
  pluginkit -a ~/Applications/snobapp.app/Contents/PlugIns/NewFile.appex 2>/dev/null || true
  open ~/Applications/snobapp.app
  echo "✓ installé dans ~/Applications et lancé"
fi
