#!/bin/sh
# Removes the Netlane helper and everything it installed. Run as root by the app.
LABEL="io.github.divezh.netlane.helper"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "/var/run/io.github.divezh.netlane.sock" /Library/Logs/Netlane-helper.log
/bin/rm -rf "/Library/Application Support/Netlane"
exit 0
