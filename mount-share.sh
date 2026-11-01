#!/bin/sh
# smb-automount — keep an SMB share mounted for the logged-in user.
#
# Installed as a system-wide LaunchAgent: one copy, runs once per user session.
# Configuration is read from config.sh (see config.example.sh).
#
# Behaviour:
#   - skips silently if the user has no stored SMB credential
#   - mounts via AppleScript "mount volume" so the Keychain item is reused
#     without ever prompting for a password
#   - never touches a mount owned by another user
#   - force-unmounts and remounts its own stale mount (after a second probe)
#   - one notification after 3 consecutive failures, then stays quiet

PATH=/usr/bin:/bin:/usr/sbin:/sbin

# launchd does not export HOME for system-wide agents, so derive it.
if [ -z "$HOME" ]; then
	HOME=$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
fi
export HOME

CONFIG=${CONFIG:-/Library/Application Support/smb-automount/config.sh}
if [ -r "$CONFIG" ]; then
	. "$CONFIG"
fi

: "${SERVER:?SERVER is not set (see config.example.sh)}"
: "${SHARE:?SHARE is not set (see config.example.sh)}"

NAS_USER=${NAS_USER:-}

if [ -n "$NAS_USER" ]; then
	URL="smb://${NAS_USER}@${SERVER}/${SHARE}"
	SHARE_KEY="${NAS_USER}@${SERVER}/${SHARE}"
else
	URL="smb://${SERVER}/${SHARE}"
	SHARE_KEY="${SERVER}/${SHARE}"
fi

STATE="$HOME/Library/Application Support/smb-automount"
LOG="$HOME/Library/Logs/smb-automount.log"
FAILFILE="$STATE/failures"

mkdir -p "$STATE" 2>/dev/null

log() {
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(id -un)" "$*" >>"$LOG" 2>/dev/null
	lines=$(wc -l <"$LOG" 2>/dev/null || echo 0)
	if [ "${lines:-0}" -gt 1000 ]; then
		tail -n 500 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
	fi
}

# macOS has no timeout(1); perl's alarm gives us a hard limit.
with_timeout() {
	/usr/bin/perl -e 'alarm shift; exec @ARGV' "$@"
}

# Read keychain attributes only. Asking for the secret (-w) blocks on a GUI
# prompt, which would hang the agent, so we never do that.
have_credential() {
	if [ -n "$NAS_USER" ]; then
		with_timeout 5 /usr/bin/security find-internet-password \
			-s "$SERVER" -a "$NAS_USER" >/dev/null 2>&1
	else
		with_timeout 5 /usr/bin/security find-internet-password \
			-s "$SERVER" >/dev/null 2>&1
	fi
}

# Emit "<mountpoint>|<owner>" for every mount of this share.
share_mounts() {
	/sbin/mount | /usr/bin/awk -v s="$SHARE_KEY" '
		$2 == "on" && index($1, s) {
			owner = ""
			for (i = 4; i <= NF; i++)
				if ($i == "by") { owner = $(i + 1); break }
			gsub(/[(),]/, "", owner)
			print $3 "|" owner
		}'
}

# Usable by the current user? A hung SMB mount fails this after the timeout.
# Uses stat(), not a directory listing: macOS TCC blocks background agents
# from reading network volume contents, but metadata calls are allowed.
usable() {
	[ -n "$1" ] && with_timeout 5 /usr/bin/stat -f '%Su' "$1" >/dev/null 2>&1
}

bump_failure() {
	n=$(cat "$FAILFILE" 2>/dev/null || echo 0)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	n=$((n + 1))
	printf '%s\n' "$n" >"$FAILFILE" 2>/dev/null
	log "failure #$n${1:+: $1}"
	if [ "$n" -eq 3 ]; then
		/usr/bin/osascript -e 'display notification "The SMB share could not be mounted. Retrying in the background." with title "SMB share unavailable"' >/dev/null 2>&1
	fi
}

clear_failures() {
	printf '0\n' >"$FAILFILE" 2>/dev/null
}

mount_share() {
	out=$(with_timeout 30 /usr/bin/osascript \
		-e 'try' \
		-e "mount volume \"${URL}\"" \
		-e 'return "ok"' \
		-e 'on error errMsg number errNum' \
		-e 'return "error " & errNum & ": " & errMsg' \
		-e 'end try' 2>>"$LOG")
	case "$out" in
		ok*) return 0 ;;
		*)   printf '%s' "$out"; return 1 ;;
	esac
}

# "mount volume" returns before the volume is actually ready, so wait for it.
wait_mounted() {
	i=0
	while [ "$i" -lt 20 ]; do
		entry=$(share_mounts | head -n 1)
		current=${entry%%|*}
		if usable "$current"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# --- main ----------------------------------------------------------------

if ! have_credential; then
	# Normal for accounts that never connected to the share: stay silent.
	exit 0
fi

entry=$(share_mounts | head -n 1)
current=${entry%%|*}
owner=${entry#*|}

if [ -n "$current" ]; then
	if usable "$current"; then
		clear_failures
		exit 0
	fi
	# A single failed probe can be a transient stall; confirm before acting.
	sleep 3
	if usable "$current"; then
		clear_failures
		exit 0
	fi
	if [ "$owner" = "$(id -un)" ]; then
		log "mount at $current is stale; forcing unmount"
		with_timeout 20 /usr/sbin/diskutil unmount force "$current" >>"$LOG" 2>&1
		sleep 1
	else
		# macOS refuses a second mount of the same share ("File exists"),
		# so a share held by another session cannot be taken over.
		log "share held by ${owner:-unknown} at $current, not accessible to $(id -un)"
		bump_failure "held by ${owner:-unknown}"
		exit 0
	fi
fi

attempt=1
while [ "$attempt" -le 3 ]; do
	if msg=$(mount_share); then
		if wait_mounted; then
			entry=$(share_mounts | head -n 1)
			log "mounted at ${entry%%|*}"
			clear_failures
			exit 0
		fi
	fi
	attempt=$((attempt + 1))
	if [ "$attempt" -le 3 ]; then
		sleep 5
	fi
done

if [ -n "$msg" ]; then
	bump_failure "mount error: $msg"
else
	bump_failure "mount did not become available"
fi
exit 1
