#!/usr/bin/env bash
# Compila l'app e la mette in app/build/Olivera.app.
#
#     ./app/build.sh          compila
#     ./app/build.sh --apri   compila e la avvia
#
# Non serve un progetto Xcode: sono tre file Swift e un Info.plist. Il vantaggio
# non e' l'eleganza, e' che si puo' rifare da riga di comando in dieci secondi
# senza aprire niente.
#
# L'app NON e' firmata. Al primo avvio macOS chiede conferma: tasto destro sopra
# l'app, "Apri", e poi "Apri" di nuovo nel pannello. Solo la prima volta.
#
# La posizione conta: l'app cerca il progetto risalendo di tre cartelle dal
# bundle, quindi build/ deve restare dentro app/ dentro il progetto. Se la si
# copia altrove ricade su ~/dev/olivera-voice.
set -euo pipefail
cd "$(dirname "$0")"

NOME="Olivera"
BUNDLE="build/$NOME.app"
MIN_MACOS="13.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NOME</string>
    <key>CFBundleDisplayName</key><string>Olivera</string>
    <key>CFBundleIdentifier</key><string>it.nerelli.olivera.guida</string>
    <key>CFBundleExecutable</key><string>$NOME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Il servizio ascolta sulla rete locale e risponde ai richiami del visore. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Per farsi trovare dal visore sulla rete di casa.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "compilo..."
swiftc \
  -target "arm64-apple-macos$MIN_MACOS" \
  -O -whole-module-optimization \
  -o "$BUNDLE/Contents/MacOS/$NOME" \
  Sources/*.swift

# L'icona: un sipario disegnato una volta e convertito in .icns. Se manca, macOS
# mette quella generica e l'app funziona uguale.
if [ -f Icona.png ] && command -v iconutil >/dev/null && command -v sips >/dev/null; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for dim in 16 32 64 128 256 512 1024; do
    sips -z $dim $dim Icona.png --out "$ICONSET/icon_${dim}x${dim}.png" >/dev/null 2>&1 || true
  done
  # i nomi che iconutil si aspetta davvero
  mv "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"     2>/dev/null || true
  mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"   2>/dev/null || true
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# Una firma ad hoc: non e' una firma vera e non toglie l'avviso al primo avvio,
# ma senza, macOS su Apple Silicon si rifiuta proprio di eseguire il binario.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "fatta: $(cd "$(dirname "$BUNDLE")" && pwd)/$NOME.app"
[ "${1:-}" = "--apri" ] && open "$BUNDLE"
exit 0
