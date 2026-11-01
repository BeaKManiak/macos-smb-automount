#!/bin/sh
# Installs the smb-automount LaunchAgent.
#
#   sudo sh install.sh
#
# If you prefer a GUI password prompt instead of the terminal, run the same
# command through osascript with "with administrator privileges".

set -e

SRC=$(cd "$(dirname "$0")" && pwd)
CONFIG="$SRC/config.sh"

if [ ! -r "$CONFIG" ]; then
	echo "error: $CONFIG not found." >&2
	echo "Copy config.example.sh to config.sh and edit it first." >&2
	exit 1
fi

. "$CONFIG"

: "${SERVER:?SERVER is not set in config.sh}"
: "${SHARE:?SHARE is not set in config.sh}"

LABEL=${LABEL:-local.smb-automount}
INTERVAL=${INTERVAL:-120}
DEST="/Library/Application Support/smb-automount"

mkdir -p "$DEST"

cp "$SRC/mount-share.sh" "$DEST/mount-share.sh"
cp "$CONFIG" "$DEST/config.sh"

chown root:wheel "$DEST" "$DEST/mount-share.sh" "$DEST/config.sh"
chmod 755 "$DEST" "$DEST/mount-share.sh"
chmod 644 "$DEST/config.sh"

sed -e "s|__LABEL__|$LABEL|g" -e "s|__INTERVAL__|$INTERVAL|g" \
	"$SRC/local.smb-automount.plist.template" >"/Library/LaunchAgents/$LABEL.plist"

chown root:wheel "/Library/LaunchAgents/$LABEL.plist"
chmod 644 "/Library/LaunchAgents/$LABEL.plist"

echo "installed:"
echo "  $DEST/mount-share.sh"
echo "  $DEST/config.sh"
echo "  /Library/LaunchAgents/$LABEL.plist"
echo
echo "Load it for the current session with:"
echo "  launchctl bootout gui/\$(id -u)/$LABEL 2>/dev/null"
echo "  launchctl bootstrap gui/\$(id -u) /Library/LaunchAgents/$LABEL.plist"
