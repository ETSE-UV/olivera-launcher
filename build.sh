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

# Le traduzioni: una tabella per lingua, dentro Contents/Resources/{it,es,en}.lproj.
# swiftc puro (senza Xcode) le legge da sole a runtime tramite NSLocalizedString/
# LocalizedStringKey - provato in docs/pingpong/RICOGNIZIONE-lingua-icona.md,
# sezione 1: basta questa cartella e CFBundleDevelopmentRegion nell'Info.plist,
# qui sotto. Un ";" dimenticato in un .strings azzera TUTTA la tabella in
# silenzio (misurato nella critica, M5): plutil -lint lo becca prima che arrivi
# a runtime, dove tornerebbe solo la chiave italiana al posto della traduzione.
for tabella in Localizzazioni/*.lproj/*.strings; do
  plutil -lint "$tabella" >/dev/null || { echo "lingua: $tabella non e' valido - controllalo" >&2; exit 1; }
done
cp -R Localizzazioni/*.lproj "$BUNDLE/Contents/Resources/"

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
    <key>CFBundleDevelopmentRegion</key><string>it</string>
    <key>CFBundleLocalizations</key>
    <array><string>it</string><string>es</string><string>en</string></array>
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

# L'icona: un ulivo disegnato una volta (Icona.svg) e convertito in .icns. Se
# manca, macOS mette quella generica e l'app funziona uguale.
#
# Il ramo precedente faceva un `sips -z` per ciascuna delle 7 misure di
# `iconutil -c iconset` (16 32 64 128 256 512 1024) e poi due soli `mv` per
# arrivare ai nomi "@2x" — ma iconutil vuole DIECI file: 5 basi (16 32 128
# 256 512) ciascuna con la propria @2x. I due `mv` (64→32@2x, 1024→512@2x)
# erano giusti: 64 e 1024 non sono taglie che iconutil vuole come base, sono
# SOLO le @2x di 32 e 512, quindi spostarle (non duplicarle) e' corretto.
# Mancavano le altre tre @2x — 16@2x, 128@2x, 256@2x — che pero' non vanno
# generate: valgono in pixel esattamente quanto le basi 32, 256, 512 gia'
# prodotte dal ciclo sips, e per quelle serve una COPIA (non uno spostamento,
# che toglierebbe la base originale che iconutil vuole anche col suo nome).
# Misurato in `docs/pingpong/RICOGNIZIONE-lingua-icona.md`: `iconutil -c icns`
# su un iconset da 7 file esce con codice 0 e non stampa NESSUN avviso (ne'
# su stdout ne' su stderr) — un .icns valido ma senza le rendition
# `icon_16x16@2x`, `icon_128x128@2x`, `icon_256x256@2x`, quindi l'icona a 16pt
# (Finder in vista elenco, Get Info, notifiche piccole) non ha mai una
# rendition nativa e macOS la scala giu' da una piu' grande, piu' sfocata di
# quanto servirebbe. Il `2>/dev/null || true` di prima nascondeva anche
# l'esito: un iconset rotto passava per compilazione riuscita. Ora si copia
# (non si sposta) ogni base che serve anche come @2x di quella sotto, e si
# fallisce ad alta voce se il risultato non ha davvero 10 file o se l'icns
# non esce.
if [ -f Icona.svg ] || [ -f Icona.png ]; then
  command -v iconutil >/dev/null || { echo "icona: manca iconutil, non posso costruire l'icns" >&2; exit 1; }
  command -v sips >/dev/null || { echo "icona: manca sips, non posso rasterizzare/ridimensionare" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "icona: manca python3, non posso rattoppare l'icns (vedi sotto)" >&2; exit 1; }

  # Con `set -e` un'uscita anticipata qui dentro (sips, iconutil, il
  # conteggio dei file) lasciava la cartella temporanea in /var/folders: il
  # trap la toglie in ogni caso, riuscita o fallimento.
  ICONA_LAVORO="$(mktemp -d)"
  trap 'rm -rf "$ICONA_LAVORO"' EXIT
  if [ -f Icona.svg ]; then
    # sips vuole il formato esplicito per un sorgente SVG: senza `-s format
    # png` fallisce con "Can't write format: public.svg-image" (misurato
    # nella ricognizione, sezione "Le prove tecniche fatte", punto 3).
    sips -s format png -z 1024 1024 Icona.svg --out "$ICONA_LAVORO/Icona.png" >/dev/null
    ICONA_PNG="$ICONA_LAVORO/Icona.png"
  else
    ICONA_PNG="Icona.png"
  fi

  ICONSET="$ICONA_LAVORO/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for dim in 16 32 64 128 256 512 1024; do
    sips -z $dim $dim "$ICONA_PNG" --out "$ICONSET/icon_${dim}x${dim}.png" >/dev/null
  done
  # Le tre @2x che il ciclo sopra non produce mai (16, 128, 256 non hanno una
  # taglia doppia generata direttamente): si copiano dalla base che ha gia'
  # la risoluzione giusta, senza toglierla dal suo nome originale.
  cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
  cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
  cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
  # 64 e 1024 non sono taglie che iconutil vuole come file "base": esistono
  # solo come @2x di 32 e 512.
  mv "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
  mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"

  N_FILE="$(find "$ICONSET" -name '*.png' | wc -l | tr -d ' ')"
  if [ "$N_FILE" != "10" ]; then
    echo "icona: l'iconset ha $N_FILE file, ne servono 10 - controlla app/build.sh" >&2
    exit 1
  fi

  # L'iconset che sta per entrare in iconutil e' quello "vero" (quello che
  # dovrebbe uscire intatto dall'icns): app/prova_icona.sh lo confronta
  # pixel per pixel con quello che iconutil restituisce riaprendo l'icns,
  # invece di rifare da capo lo stesso ciclo sips (due copie della stessa
  # logica che potrebbero divergere in silenzio). Copiato, non spostato:
  # ICONA_LAVORO sparisce col trap qui sopra, questa resta in build/ come
  # $BUNDLE.
  rm -rf "build/AppIcon.iconset"
  cp -R "$ICONSET" "build/AppIcon.iconset"

  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  [ -f "$BUNDLE/Contents/Resources/AppIcon.icns" ] || { echo "icona: iconutil non ha prodotto AppIcon.icns" >&2; exit 1; }

  # Rattoppo dell'icns: misurato (critica del 16 settembre, confermato di
  # nuovo qui riaprendo l'icns con `iconutil -c iconset` e confrontando
  # pixel per pixel contro build/AppIcon.iconset appena scritto) che
  # `iconutil -c icns` scrive le rendition a 16 e 32 px @1x (i chunk `ic04`
  # e `ic05`, ARGB in packbits) in un flusso che i decodificatori di Apple -
  # sia `iconutil -c iconset` sia IconServices, quindi anche il Dock - non
  # rileggono fino in fondo: perdono l'ultimo token del piano blu, cioe' la
  # ripetizione finale, che vale 71 byte a 16 px e 42 a 32 px. Il risultato
  # e' una fascia gialla in basso su due rendition su dieci (macOS 27.0
  # 26A428, verificato di nuovo in questa sessione: 113 pixel diversi su
  # tutte e dieci le taglie riaperte, tutti in icon_16x16.png e
  # icon_32x32.png). Il flusso scritto da iconutil e' corretto byte per
  # byte (letto e ridecodificato a mano con la regola packbits dell'icns):
  # e' solo l'ultimo token che va perso in lettura. Un byte di riempimento
  # in coda al corpo di ic04/ic05 (dopo la firma "ARGB") gli da' quel token
  # in piu' senza cambiare un pixel del contenuto, e il conteggio pixel
  # torna a zero su tutte e dieci le rendition (vedi prova_icona.sh).
  # Alternative provate e scartate: chunk `icp4`/`icp5` col PNG dentro (il
  # sistema li decodifica come rumore, non come l'immagine); l'icns scritto
  # da Pillow (salta proprio le rendition a 16@1x e 32@1x, iconset da 8 file
  # non da 10).
  python3 - "$BUNDLE/Contents/Resources/AppIcon.icns" <<'PYEOF'
import struct, sys
percorso = sys.argv[1]
dati = open(percorso, "rb").read()
assert dati[:4] == b"icns", "non e' un file icns"
totale = struct.unpack(">I", dati[4:8])[0]
assert totale == len(dati), "lunghezza dichiarata diversa da quella del file"
i = 8
corpo_nuovo = bytearray()
while i < totale:
    tipo = dati[i:i + 4]
    n = struct.unpack(">I", dati[i + 4:i + 8])[0]
    corpo = dati[i + 8:i + n]
    if tipo in (b"ic04", b"ic05") and corpo[:4] == b"ARGB":
        corpo = corpo + b"\x00"
    corpo_nuovo += struct.pack(">4sI", tipo, 8 + len(corpo)) + corpo
    i += n
finale = b"icns" + struct.pack(">I", 8 + len(corpo_nuovo)) + bytes(corpo_nuovo)
open(percorso, "wb").write(finale)
PYEOF
fi

# Una firma ad hoc: non e' una firma vera e non toglie l'avviso al primo avvio,
# ma senza, macOS su Apple Silicon si rifiuta proprio di eseguire il binario.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "fatta: $(cd "$(dirname "$BUNDLE")" && pwd)/$NOME.app"
[ "${1:-}" = "--apri" ] && open "$BUNDLE"
exit 0
