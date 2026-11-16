#!/bin/sh
# Installs smb-automount for the current user. No sudo required.
#
#   sh install.sh              install for the current account
#   sh install.sh --uninstall  remove this account's install
#
# Files written:
#   ~/Library/Application Support/smb-automount/mount-share.sh
#   ~/Library/Application Support/smb-automount/config.sh
#   ~/Library/LaunchAgents/<LABEL>.plist

set -eu

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ -n "${HOME:-}" ] || die "HOME is not set"

SRC=$(cd "$(dirname "$0")" && pwd)
CONFIG="$SRC/config.sh"
DEST="$HOME/Library/Application Support/smb-automount"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL_DEFAULT="local.smb-automount"
INTERVAL_DEFAULT=120

usage() {
	cat <<'EOF'
usage: sh install.sh [--uninstall]

  (no argument)  install smb-automount for the current user
  --uninstall    stop the agent and remove this user's installed files
EOF
}

read_label() {
	# Prefer the installed config, then the repository config.
	file=""
	if [ -r "$DEST/config.sh" ]; then
		file="$DEST/config.sh"
	elif [ -r "$CONFIG" ]; then
		file="$CONFIG"
	fi
	if [ -n "$file" ]; then
		label=$( ( . "$file" >/dev/null 2>&1; printf '%s' "${LABEL:-}" ) )
	else
		label=""
	fi
	printf '%s\n' "${label:-$LABEL_DEFAULT}"
}

uninstall() {
	label=$(read_label)
	launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
	rm -f "$AGENT_DIR/$label.plist"
	rm -rf "$DEST"
	printf 'removed smb-automount for %s\n' "$(id -un)"
	printf '  %s/%s.plist\n' "$AGENT_DIR" "$label"
	printf '  %s\n' "$DEST"
	printf 'The log was kept: %s/Library/Logs/smb-automount.log\n' "$HOME"
	printf 'Remove it manually if you no longer need it.\n'
	if [ -e "/Library/Application Support/smb-automount" ]; then
		printf 'note: an old system-wide install still exists under /Library; remove it manually.\n'
	fi
}

case "${1:-}" in
	--uninstall)
		uninstall
		exit 0
		;;
	-h|--help)
		usage
		exit 0
		;;
	"")
		;;
	*)
		usage >&2
		exit 1
		;;
esac

[ -r "$CONFIG" ] || die "$CONFIG not found. Copy config.example.sh to config.sh and edit it first."

# shellcheck disable=SC1091
. "$CONFIG"

[ -n "${SERVER:-}" ] || die "SERVER is not set in config.sh"
[ -n "${SHARE:-}" ] || die "SHARE is not set in config.sh"

LABEL=${LABEL:-$LABEL_DEFAULT}
INTERVAL=${INTERVAL:-$INTERVAL_DEFAULT}

case "$LABEL" in
	*[!A-Za-z0-9._-]*) die "LABEL may only contain letters, digits, dot, dash and underscore" ;;
esac
case "$INTERVAL" in
	''|*[!0-9]*) die "INTERVAL must be a positive integer" ;;
esac
[ "$INTERVAL" -gt 0 ] || die "INTERVAL must be a positive integer"

# Refuse to install next to the old system-wide version: two agents would race.
LEGACY=""
[ -e "/Library/Application Support/smb-automount" ] && LEGACY=1
for f in /Library/LaunchAgents/*smb-automount*; do
	[ -e "$f" ] && LEGACY=1
done
if [ -n "$LEGACY" ]; then
	cat >&2 <<'EOF'
error: an old system-wide install is still present.

Remove it first (run as an administrator):

  sudo launchctl bootout system/local.smb-automount 2>/dev/null
  launchctl bootout gui/$(id -u)/local.smb-automount 2>/dev/null
  sudo rm -f /Library/LaunchAgents/*smb-automount*.plist
  sudo rm -rf "/Library/Application Support/smb-automount"

Then run this script again.
EOF
	exit 1
fi

mkdir -p "$DEST" "$AGENT_DIR" "$HOME/Library/Logs"

for f in "$AGENT_DIR"/*smb-automount*.plist; do
	[ -e "$f" ] || continue
	[ "$f" = "$AGENT_DIR/$LABEL.plist" ] && continue
	old=$(basename "$f" .plist)
	printf 'warning: another smb-automount agent is installed: %s\n' "$f" >&2
	printf '  remove it with: launchctl bootout gui/$(id -u)/%s && rm "%s"\n' "$old" "$f" >&2
done

cp "$SRC/mount-share.sh" "$DEST/mount-share.sh"
cp "$CONFIG" "$DEST/config.sh"
chmod 755 "$DEST" "$DEST/mount-share.sh"
chmod 644 "$DEST/config.sh"

# Escape characters that sed treats specially in the replacement, and keep the
# XML valid if the home path contains XML metacharacters.
home_xml=$(printf '%s' "$HOME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
home_sed=$(printf '%s' "$home_xml" | sed 's/[\\&|]/\\&/g')

tmp="$AGENT_DIR/.$LABEL.plist.$$"
sed -e "s|__LABEL__|$LABEL|g" \
	-e "s|__INTERVAL__|$INTERVAL|g" \
	-e "s|__HOME__|$home_sed|g" \
	"$SRC/local.smb-automount.plist.template" >"$tmp"
chmod 644 "$tmp"
mv "$tmp" "$AGENT_DIR/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$LABEL.plist"; then
	printf 'error: launchctl could not load %s.plist\n' "$LABEL" >&2
	printf 'Try: launchctl bootout gui/$(id -u)/%s && launchctl bootstrap gui/$(id -u) "%s/%s.plist"\n' \
		"$LABEL" "$AGENT_DIR" "$LABEL" >&2
	exit 1
fi

printf 'installed smb-automount for %s\n' "$(id -un)"
printf '  %s\n' "$DEST/mount-share.sh"
printf '  %s\n' "$DEST/config.sh"
printf '  %s/%s.plist\n' "$AGENT_DIR" "$LABEL"
printf '\nverify:\n'
printf '  launchctl print gui/$(id -u)/%s\n' "$LABEL"
printf '  tail -f %s/Library/Logs/smb-automount.log\n' "$HOME"
