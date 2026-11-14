#!/bin/sh
# Netlane for macOS, installed in one line:
#   curl -fsSL https://github.com/divezh/netlane-macos/releases/latest/download/install.sh | sh
# Downloads the archive of the latest release, its SHA-256 and the owner's signature, checks them, puts
# Netlane.app into /Applications and opens it. Files downloaded by curl carry no quarantine mark, so macOS opens the
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
# The owner's release key (netlane-release.pub): the private half is not on GitHub.
curl -fsSL "$LATEST/Netlane-macos.zip.sig" -o "$WORK/Netlane-macos.zip.sig" || { echo "У релиза нет подписи владельца, установка отменена." >&2; exit 1; }
cat > "$WORK/release.pub" <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtcoVFvdfswZyFlDqvHPR4ZS7wxQL
q7iwNHtv+nx0GBdMsfRqNxJEEuOmJQhX8K87n59fJ8x5K7SFVPT3EbPWdg==
-----END PUBLIC KEY-----
KEY
/usr/bin/openssl dgst -sha256 -verify "$WORK/release.pub" -signature "$WORK/Netlane-macos.zip.sig" "$WORK/Netlane-macos.zip" >/dev/null 2>&1 ||
    { echo "Подпись архива не прошла проверку, установка отменена." >&2; exit 1; }

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
