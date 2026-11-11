#!/bin/sh
# Removes Netlane from this Mac: the app, the VPN helper, settings and logs.
#   curl -fsSL https://raw.githubusercontent.com/divezh/netlane-macos/main/uninstall.sh | sh
set -u
echo "Netlane: удаляю приложение, помощник VPN, настройки и журналы. Нужен пароль администратора."
osascript -e 'quit app "Netlane"' 2>/dev/null
pkill -x Netlane 2>/dev/null
sudo /bin/launchctl bootout system/io.github.divezh.netlane.helper 2>/dev/null
sudo rm -f /Library/LaunchDaemons/io.github.divezh.netlane.helper.plist \
    /Library/PrivilegedHelperTools/io.github.divezh.netlane.helper \
    /var/run/io.github.divezh.netlane.sock /Library/Logs/Netlane-helper.log
sudo rm -rf "/Library/Application Support/Netlane" /Applications/Netlane.app /Applications/.Netlane.app.previous-*
sudo /usr/sbin/pkgutil --forget io.github.divezh.netlane >/dev/null 2>&1
rm -f ~/Library/LaunchAgents/io.github.divezh.netlane.plist
rm -rf ~/Library/Application\ Support/Netlane ~/Library/Logs/Netlane
echo "Готово: Netlane удалён."
