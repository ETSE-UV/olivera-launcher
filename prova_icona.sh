#!/usr/bin/env bash
# Prova che l'icona costruita da build.sh sia quella vera e non quella
# incompleta che il ramo rotto produceva in silenzio.
#
#     ./app/build.sh && ./app/prova_icona.sh
#
# Il difetto misurato in docs/pingpong/RICOGNIZIONE-lingua-icona.md non fa
# fallire niente da solo: `iconutil -c icns` su un iconset a 7 file esce con
# codice 0 e non scrive un avviso ne' su stdout ne' su stderr. Quindi una
# prova che si limita a "il file .icns esiste" passa anche sul ramo rotto:
# serve riaprire l'icns con `iconutil -c iconset` all'indietro e contare
# davvero i file, uno per uno per nome. E' la stessa tecnica usata nella
# ricognizione per misurare il guasto (7 file, non 10) prima di scriverne
# la correzione.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE="build/Olivera.app"
ICNS="$BUNDLE/Contents/Resources/AppIcon.icns"

verdi=0
ok() { verdi=$((verdi + 1)); echo "ok  $1"; }
guasto() { echo "GUASTO  $1" >&2; exit 1; }

[ -d "$BUNDLE" ] || guasto "$BUNDLE non esiste: lancia prima ./app/build.sh"
[ -f "$ICNS" ] || guasto "$ICNS non esiste: build.sh non ha prodotto l'icona (o il ramo icona non e' partito perche' manca Icona.svg/Icona.png)"
ok "$ICNS esiste"

# All'indietro: da .icns a iconset, per vedere quello che iconutil ha messo
# dentro davvero, non quello che build.sh ha provato a mettere. E' l'unico
# modo misurato che smaschera un icns "riuscito" ma incompleto.
CARTELLA_PROVA="$(mktemp -d)"
trap 'rm -rf "$CARTELLA_PROVA"' EXIT
iconutil -c iconset "$ICNS" -o "$CARTELLA_PROVA/AppIcon.iconset" \
  || guasto "iconutil -c iconset non riesce a riaprire $ICNS (icns corrotto o vuoto)"
ok "iconutil riapre l'icns senza errori"

N_FILE="$(find "$CARTELLA_PROVA/AppIcon.iconset" -name '*.png' | wc -l | tr -d ' ')"
[ "$N_FILE" = "10" ] || guasto "l'iconset riaperto ha $N_FILE file, ne servono 10 (era il difetto: 7 su 10, iconutil zitto)"
ok "l'iconset riaperto ha 10 file"

# I dieci nomi esatti, non solo il conteggio: un iconset con 10 file ma i
# nomi sbagliati (es. due copie di icon_32x32.png con nomi diversi) supera
# il controllo sopra e fallisce comunque in Finder.
ATTESI="icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png"
for nome in $ATTESI; do
  [ -f "$CARTELLA_PROVA/AppIcon.iconset/$nome" ] || guasto "manca $nome nell'iconset riaperto"
done
ok "tutti e dieci i nomi attesi ci sono (16/32/128/256/512, base e @2x)"

# La taglia in pixel di TUTTE E DIECI, non solo della 1024: controllare solo
# la piu' grande lascia passare un iconset dove sips ha scalato storto una
# taglia intermedia (es. 128 finita a 127x129 per arrotondamento) - non e'
# mai successo qui, ma il ciclo costa poco visto che l'iconset e' gia'
# riaperto (critica del 16 settembre, "consigliate" punto 4).
ATTESE_PX="icon_16x16.png:16 icon_16x16@2x.png:32 icon_32x32.png:32 icon_32x32@2x.png:64 icon_128x128.png:128 icon_128x128@2x.png:256 icon_256x256.png:256 icon_256x256@2x.png:512 icon_512x512.png:512 icon_512x512@2x.png:1024"
for coppia in $ATTESE_PX; do
  nome="${coppia%%:*}"
  dim="${coppia##*:}"
  file="$CARTELLA_PROVA/AppIcon.iconset/$nome"
  PX_W="$(sips -g pixelWidth "$file" | awk '/pixelWidth/{print $2}')"
  PX_H="$(sips -g pixelHeight "$file" | awk '/pixelHeight/{print $2}')"
  [ "$PX_W" = "$dim" ] && [ "$PX_H" = "$dim" ] \
    || guasto "$nome e' ${PX_W}x${PX_H}, non ${dim}x${dim}"
done
ok "tutte e dieci le rendition hanno la taglia in pixel attesa (sips -g pixelWidth/pixelHeight)"

# Pixel per pixel contro l'iconset vero, non solo la taglia: misurato il 16
# settembre (critica del critico Opus) che `iconutil -c icns` scrive le
# rendition a 16 e 32 px @1x (chunk `ic04`/`ic05`, ARGB in packbits) in un
# flusso che i decodificatori di Apple - iconutil compreso - non rileggono
# fino in fondo, perdendo l'ultimo token del piano blu: 71 pixel diversi su
# icon_16x16.png, 42 su icon_32x32.png, tutti nella fascia in basso (il
# canale B a 0 invece che al suo valore, una banda gialla). Un controllo di
# sola taglia non se ne accorge: le dimensioni restano giuste, cambia solo
# il colore. build.sh lascia l'iconset "vero" (quello dato in pasto a
# iconutil, prima della conversione) in build/AppIcon.iconset apposta per
# questo confronto, cosi' la prova non deve rifare da capo il ciclo sips
# (due copie della stessa logica che potrebbero divergere in silenzio).
ICONSET_VERO="build/AppIcon.iconset"
[ -d "$ICONSET_VERO" ] || guasto "$ICONSET_VERO non esiste: build.sh non l'ha lasciato (versione vecchia di build.sh?)"
PYTHON_VENV="../.venv/bin/python3"
[ -x "$PYTHON_VENV" ] || guasto "manca $PYTHON_VENV (Pillow): il confronto pixel per pixel lo richiede"

# Lo script Python va scritto su file a se' stante: un heredoc sulla stessa
# riga di piu' argomenti tra virgolette (qui: interprete, due percorsi, la
# lista attesi) e con un apostrofo nel corpo (i commenti in italiano ne sono
# pieni) manda in confusione il parser di bash, che si mette a cercare un
# apice di chiusura dentro il corpo del heredoc anche se il terminatore e'
# gia' fra apici singoli - misurato qui isolando il caso minimo. Un file
# separato aggira il problema alla radice.
CONFRONTO_PY="$CARTELLA_PROVA/confronta_pixel.py"
cat > "$CONFRONTO_PY" <<'PYEOF'
import sys
import warnings
from PIL import Image

warnings.filterwarnings("ignore")  # getdata() e' deprecato in Pillow 14 ma ancora presente in 12.3.0 di questo .venv
riaperto, vero, attese = sys.argv[1], sys.argv[2], sys.argv[3]
nomi = [c.split(":")[0] for c in attese.split()]
totale_diversi = 0
dettagli = []
for nome in nomi:
    a = Image.open(f"{riaperto}/{nome}").convert("RGBA")
    b = Image.open(f"{vero}/{nome}").convert("RGBA")
    if a.size != b.size:
        dettagli.append(f"{nome}: dimensioni diverse {a.size} vs {b.size}")
        totale_diversi += 1
        continue
    diversi = sum(1 for p, q in zip(a.getdata(), b.getdata()) if p != q)
    if diversi:
        dettagli.append(f"{nome}: {diversi} pixel diversi")
    totale_diversi += diversi
if totale_diversi:
    print("GUASTO " + "; ".join(dettagli))
    sys.exit(1)
print("0 pixel diversi su tutte e dieci le rendition")
PYEOF

ESITO_PIXEL="$("$PYTHON_VENV" "$CONFRONTO_PY" "$CARTELLA_PROVA/AppIcon.iconset" "$ICONSET_VERO" "$ATTESE_PX")" && ESITO_CODICE=0 || ESITO_CODICE=$?
if [ "$ESITO_CODICE" != "0" ]; then
  guasto "confronto pixel per pixel: $ESITO_PIXEL"
fi
ok "confronto pixel per pixel con l'iconset vero: $ESITO_PIXEL"

# Vederla davvero, non solo misurarla: NSWorkspace.shared.icon(forFile:)
# disegna l'icona COME la mostra il sistema, maschera arrotondata, rientro
# e vetro compresi (la stessa cosa che si vedrebbe nel Dock), senza il
# permesso di Screen Recording che screencapture invece richiede - misurato
# la prima volta dal critico Opus il 16 settembre, qui rifatto per lasciare
# un'immagine vera nel rapporto invece di un "dedotto". E' un supplemento,
# non una prova: se manca swiftc o la compilazione fallisce, si segnala e si
# va avanti, perche' l'app compila e l'icns e' gia' verificato sopra.
if command -v swiftc >/dev/null; then
  ANTEPRIMA_SWIFT="$CARTELLA_PROVA/anteprima_icona.swift"
  cat > "$ANTEPRIMA_SWIFT" <<'SWIFTEOF'
import AppKit
let percorso = CommandLine.arguments[1]
let uscita = CommandLine.arguments[2]
let lato: CGFloat = 512
let icona = NSWorkspace.shared.icon(forFile: percorso)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(lato), pixelsHigh: Int(lato),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
icona.draw(in: NSRect(x: 0, y: 0, width: lato, height: lato))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: uscita))
SWIFTEOF
  ANTEPRIMA_BIN="$CARTELLA_PROVA/anteprima_icona"
  ANTEPRIMA_PNG="build/anteprima_icona_sistema.png"
  # NSWorkspace.shared.icon(forFile:) vuole un percorso assoluto: con quello
  # relativo ("build/Olivera.app") restituisce zitto l'icona generica del
  # "documento bianco" invece di quella dell'app - misurato qui, prima
  # versione di questo passo, confrontando l'immagine ottenuta con quella
  # attesa.
  if swiftc "$ANTEPRIMA_SWIFT" -o "$ANTEPRIMA_BIN" 2>/dev/null && "$ANTEPRIMA_BIN" "$(pwd)/$BUNDLE" "$ANTEPRIMA_PNG" 2>/dev/null; then
    ok "anteprima dell'icona composta dal sistema salvata in app/$ANTEPRIMA_PNG"
  else
    echo "nota: l'anteprima via NSWorkspace non e' riuscita, non blocca la prova"
  fi
else
  echo "nota: manca swiftc, salto l'anteprima via NSWorkspace (non blocca la prova)"
fi

echo
echo "tutto verde ($verdi controlli)"
