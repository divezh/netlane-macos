#!/bin/sh
# Netlane for macOS, installed in one line:
#   curl -fsSL https://raw.githubusercontent.com/divezh/netlane-macos/main/install.sh | sh
# Downloads the archive of the latest release and its SHA-256, checks them, puts Netlane.app into
# /Applications and opens it. Files downloaded by curl carry no quarantine mark, so macOS opens the
# app without the «unidentified developer» warning.
set -eu
LATEST="https://github.com/divezh/netlane-macos/releases/latest/download"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ "$(uname -s)" = Darwin ] || { echo "Netlane для macOS устанавливается только на Mac." >&2; exit 1; }
echo "Netlane: скачиваю последний релиз…"
curl -fL --progress-bar "$LATEST/Netlane-macos.zip" -o "$WORK/Netlane-macos.zip"
curl -fsSL "$LATEST/Netlane-macos.zip.sha256" -o "$WORK/sum"
SHA="$(cut -d' ' -f1 "$WORK/sum")"
ACTUAL="$(shasum -a 256 "$WORK/Netlane-macos.zip" | cut -d' ' -f1)"
[ -n "$SHA" ] && [ "$ACTUAL" = "$SHA" ] || { echo "Контрольная сумма не совпала, установка отменена." >&2; exit 1; }

/usr/bin/ditto -x -k "$WORK/Netlane-macos.zip" "$WORK/app"
[ -d "$WORK/app/Netlane.app" ] || { echo "В архиве нет Netlane.app." >&2; exit 1; }
/usr/bin/pkill -x Netlane 2>/dev/null && sleep 1 || true
if [ -w /Applications ]; then
    rm -rf /Applications/Netlane.app
    /usr/bin/ditto "$WORK/app/Netlane.app" /Applications/Netlane.app
else
    echo "Нужен пароль администратора, чтобы положить Netlane в «Программы»."
    sudo rm -rf /Applications/Netlane.app
    sudo /usr/bin/ditto "$WORK/app/Netlane.app" /Applications/Netlane.app
    sudo /usr/sbin/chown -R "$(id -u):$(id -g)" /Applications/Netlane.app
fi
/usr/bin/xattr -dr com.apple.quarantine /Applications/Netlane.app 2>/dev/null || true
open /Applications/Netlane.app
echo "Готово: Netlane в «Программах»."
