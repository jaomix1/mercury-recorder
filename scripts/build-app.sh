#!/bin/zsh
# Compila la app y arma build/Grabadora.app (firma ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Grabadora.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Grabadora" "$APP/Contents/MacOS/Grabadora"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --identifier local.grabadora.reuniones "$APP"
echo "Listo: $PWD/$APP"
