#!/bin/sh
# Netlane for macOS, installed in one line:
#   curl -fsSL https://raw.githubusercontent.com/divezh/netlane-macos/main/install.sh | sh
# Downloads the latest version from the update channel, checks its SHA-256, puts Netlane.app into
# /Applications and opens it. Files downloaded by curl carry no quarantine mark, so macOS opens the
# app without the «unidentified developer» warning.
set -eu
REPO="divezh/netlane-macos"
CHANNEL="https://raw.githubusercontent.com/$REPO/updates/latest.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ "$(uname -s)" = Darwin ] || { echo "Netlane для macOS устанавливается только на Mac." >&2; exit 1; }
echo "Netlane: читаю канал обновлений…"
curl -fsSL "$CHANNEL" -o "$WORK/latest.json"
field() { /usr/bin/plutil -extract "$1" raw -o - "$WORK/latest.json"; }
VERSION="$(field version)"; URL="$(field url)"; SHA="$(field sha256)"
case "$URL" in https://*) ;; *) echo "Неожиданная ссылка в канале обновлений." >&2; exit 1 ;; esac

echo "Netlane $VERSION: скачиваю…"
curl -fL --progress-bar "$URL" -o "$WORK/Netlane-macos.zip"
ACTUAL="$(shasum -a 256 "$WORK/Netlane-macos.zip" | cut -d' ' -f1)"
[ "$ACTUAL" = "$SHA" ] || { echo "Контрольная сумма не совпала, установка отменена." >&2; exit 1; }

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
echo "Готово: Netlane $VERSION в «Программах»."
