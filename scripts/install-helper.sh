#!/bin/sh
# Installs the Netlane helper. Run as root by the app (one administrator prompt):
#   install-helper.sh <Netlane.app/Contents/Resources> <uid of the user>
# The helper and the engine are copied into root-owned folders, so replacing the app later
# cannot change what runs as root.
set -eu
SRC="$1"
USER_ID="$2"
LABEL="io.github.divezh.netlane.helper"
SUPPORT="/Library/Application Support/Netlane"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HELPER="/Library/PrivilegedHelperTools/$LABEL"

case "$USER_ID" in ''|*[!0-9]*) echo "bad uid" >&2; exit 2 ;; esac
[ -f "$SRC/NetlaneHelper" ] && [ -f "$SRC/engine/trusttunnel_client" ] || { echo "helper or engine is missing in the app" >&2; exit 2; }

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/mkdir -p /Library/PrivilegedHelperTools "$SUPPORT/engine" "$SUPPORT/run"
/usr/bin/install -o root -g wheel -m 755 "$SRC/NetlaneHelper" "$HELPER"
/usr/bin/install -o root -g wheel -m 755 "$SRC/engine/trusttunnel_client" "$SUPPORT/engine/trusttunnel_client"
/usr/sbin/chown -R root:wheel "$SUPPORT"
/bin/chmod 755 "$SUPPORT" "$SUPPORT/engine"
/bin/chmod 700 "$SUPPORT/run"
/usr/bin/xattr -d com.apple.quarantine "$HELPER" "$SUPPORT/engine/trusttunnel_client" 2>/dev/null || true

/bin/cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER</string>
        <string>--uid</string>
        <string>$USER_ID</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/Library/Logs/Netlane-helper.log</string>
</dict>
</plist>
PLIST
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
