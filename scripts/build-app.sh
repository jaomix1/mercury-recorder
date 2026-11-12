#!/bin/zsh
# Compila la app y arma build/mercury-recorder.app.
#
# Firma: usa el certificado de firma de código "mercury-recorder" (creado en
# Acceso a Llaveros) si existe; así macOS reconoce la app como la misma después
# de cada compilación y no vuelve a pedir los permisos. Si no existe, firma
# ad-hoc (macOS puede volver a pedir los permisos al recompilar).
# Otro nombre de certificado: GRABADORA_FIRMA="Mi certificado" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/mercury-recorder.app
rm -rf "$APP" build/Grabadora.app  # build/Grabadora.app: nombre anterior de la app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/mercury-recorder" "$APP/Contents/MacOS/mercury-recorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # se genera con scripts/make-icon.sh

IDENTITY="${GRABADORA_FIRMA:-mercury-recorder}"
# Sin -v: un certificado autofirmado no es "de confianza" para el sistema, pero sirve para firmar.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier local.grabadora.reuniones "$APP"
    echo "Firmada con el certificado «$IDENTITY»."
else
    codesign --force --sign - --identifier local.grabadora.reuniones "$APP"
    echo "Firmada ad-hoc (no se encontró el certificado «$IDENTITY»)."
fi
echo "Listo: $PWD/$APP"
