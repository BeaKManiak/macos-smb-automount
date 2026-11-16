#!/bin/sh
# smb-automount — keep an SMB share mounted for the logged-in user.
#
# Installed as a per-user LaunchAgent:
#   ~/Library/LaunchAgents/local.smb-automount.plist
#
# Configuration:
#   ~/Library/Application Support/smb-automount/config.sh
#
# Behaviour:
#   - skips (and says so once) if this user has no stored SMB credential
#   - mounts via AppleScript "mount volume" so the Keychain item is reused
#     without ever prompting for a password
#   - only inspects and unmounts mounts owned by the current user
#   - force-unmounts its own stale mount after a second probe
#   - one notification after 3 consecutive failures, then stays quiet

PATH=/usr/bin:/bin:/usr/sbin:/sbin

# launchd does not always export HOME, so derive it.
if [ -z "${HOME:-}" ]; then
	HOME=$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
fi
export HOME

ME=$(id -un)
STATE="$HOME/Library/Application Support/smb-automount"
LOG="$HOME/Library/Logs/smb-automount.log"
FAILFILE="$STATE/failures"
LOCK="$STATE/lock"
CONFIG=${CONFIG:-"$STATE/config.sh"}

mkdir -p "$STATE" "$HOME/Library/Logs" 2>/dev/null

log() {
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ME" "$*" >>"$LOG" 2>/dev/null || return 0
	lines=$(wc -l <"$LOG" 2>/dev/null | tr -d '[:space:]')
	case "$lines" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$lines" -gt 1000 ]; then
		tail -n 500 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
	fi
}

if [ ! -r "$CONFIG" ]; then
	log "configuration not found at $CONFIG; run install.sh"
	exit 1
fi
. "$CONFIG"

if [ -z "${SERVER:-}" ] || [ -z "${SHARE:-}" ]; then
	log "SERVER or SHARE is not set in $CONFIG"
	exit 1
fi
NAS_USER=${NAS_USER:-}

if [ -n "$NAS_USER" ]; then
	URL="smb://${NAS_USER}@${SERVER}/${SHARE}"
	MOUNT_URL="//${NAS_USER}@${SERVER}/${SHARE}"
	MOUNT_URL_ALT=""
else
	URL="smb://${SERVER}/${SHARE}"
	MOUNT_URL="//${SERVER}/${SHARE}"
	MOUNT_URL_ALT="//guest@${SERVER}/${SHARE}"
fi

# macOS has no timeout(1); perl's alarm gives us a hard limit.
with_timeout() {
	/usr/bin/perl -e 'alarm shift; exec @ARGV' "$@"
}

# Metadata-only Keychain lookup. Asking for the secret (-w) would block on a
# GUI prompt, which would hang the agent, so we never do that.
have_credential() {
	if [ -n "$NAS_USER" ]; then
		with_timeout 5 /usr/bin/security find-internet-password \
			-s "$SERVER" -a "$NAS_USER" -r 'smb ' >/dev/null 2>&1
	else
		with_timeout 5 /usr/bin/security find-internet-password \
			-s "$SERVER" -r 'smb ' >/dev/null 2>&1
	fi
}

# Emit "<mountpoint>|<owner>" for every mount of this share. The comparison is
# exact (one share name may be the prefix of another) and case-insensitive.
share_mounts() {
	/sbin/mount | MOUNT_URL="$MOUNT_URL" MOUNT_URL_ALT="$MOUNT_URL_ALT" /usr/bin/awk '
		function norm(s) { gsub(/\\040/, " ", s); return tolower(s) }
		function matches(s) {
			if (norm(s) == norm(ENVIRON["MOUNT_URL"])) return 1
			return ENVIRON["MOUNT_URL_ALT"] != "" && norm(s) == norm(ENVIRON["MOUNT_URL_ALT"])
		}
		$2 == "on" && matches($1) {
			owner = ""
			for (i = 4; i <= NF; i++)
				if ($i == "by") { owner = $(i + 1); break }
			gsub(/[(),]/, "", owner)
			path = $3
			gsub(/\\040/, " ", path)
			print path "|" owner
		}'
}

# Mountpoints of this share owned by the current user.
our_mounts() {
	share_mounts | /usr/bin/awk -F'|' -v u="$ME" '$2 == u { print $1 }'
}

# Usable by the current user? A hung SMB mount fails this after the timeout.
# Uses stat(), not a directory listing: macOS TCC blocks background agents from
# reading network volume contents, but metadata calls are allowed. Ownership is
# checked too, so another user's mount never counts as healthy.
usable() {
	[ -n "$1" ] || return 1
	owner=$(with_timeout 5 /usr/bin/stat -f '%Su' "$1" 2>/dev/null) || return 1
	[ "$owner" = "$ME" ]
}

first_usable_our_mount() {
	our_mounts >"$STATE/.mounts" 2>/dev/null || return 1
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		if usable "$p"; then
			printf '%s\n' "$p"
			return 0
		fi
	done <"$STATE/.mounts"
	return 1
}

force_unmount_ours() {
	our_mounts >"$STATE/.mounts" 2>/dev/null || return 0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		log "mount at $p is stale; forcing unmount"
		with_timeout 20 /usr/sbin/diskutil unmount force "$p" >>"$LOG" 2>&1
		if share_mounts | /usr/bin/grep -F "$p|" >/dev/null 2>&1; then
			log "could not unmount $p"
		fi
	done <"$STATE/.mounts"
}

acquire_lock() {
	# Fast path: take the lock and record who owns it.
	if mkdir "$LOCK" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null
		trap 'rm -rf "$LOCK" 2>/dev/null' EXIT HUP INT TERM
		return 0
	fi

	# Someone else has it. If the recorded process is gone, the lock is stale
	# (for example after "launchctl kickstart -k" killed the previous run).
	holder=$(cat "$LOCK/pid" 2>/dev/null)
	case "$holder" in
		''|*[!0-9]*) holder=0 ;;
	esac
	if [ "$holder" -gt 0 ] && kill -0 "$holder" 2>/dev/null; then
		return 1
	fi

	rm -rf "$LOCK" 2>/dev/null
	if mkdir "$LOCK" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null
		trap 'rm -rf "$LOCK" 2>/dev/null' EXIT HUP INT TERM
		return 0
	fi
	return 1
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
	MOUNTED_PATH=""
	MOUNT_ERROR=""
	out=$(with_timeout 30 /usr/bin/osascript \
		-e 'try' \
		-e "set m to mount volume \"${URL}\"" \
		-e 'try' \
		-e 'set m to POSIX path of m' \
		-e 'on error' \
		-e 'set m to m as text' \
		-e 'end try' \
		-e 'return m' \
		-e 'on error errMsg number errNum' \
		-e 'return "error " & errNum & ": " & errMsg' \
		-e 'end try' 2>>"$LOG")
	rc=$?
	if [ "$rc" -ne 0 ]; then
		MOUNT_ERROR="mount volume exited with status $rc"
		return 1
	fi
	case "$out" in
		error*)
			MOUNT_ERROR=$out
			return 1
			;;
		"")
			MOUNT_ERROR="mount volume returned no path"
			return 1
			;;
		*)
			MOUNTED_PATH=${out%/}
			return 0
			;;
	esac
}

# "mount volume" returns before the volume is ready, so wait for it.
wait_mounted() {
	want=${1:-}
	i=0
	while [ "$i" -lt 20 ]; do
		if [ -n "$want" ] && usable "$want"; then
			MOUNTED_PATH=$want
			return 0
		fi
		if p=$(first_usable_our_mount); then
			MOUNTED_PATH=$p
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# --- main ----------------------------------------------------------------

if ! have_credential; then
	# Normal for accounts that never connected to the share: log the state
	# once so a missing credential can be diagnosed.
	who="${NAS_USER:-guest}@$SERVER"
	if [ ! -e "$STATE/no-credential" ] || [ "$(cat "$STATE/no-credential" 2>/dev/null)" != "$who" ]; then
		log "no SMB keychain credential for $who; skipping (connect once via Finder and save the password)"
		printf '%s\n' "$who" >"$STATE/no-credential" 2>/dev/null
	fi
	exit 0
fi
if [ -e "$STATE/no-credential" ]; then
	log "SMB keychain credential found; resuming"
	rm -f "$STATE/no-credential" 2>/dev/null
fi

if ! acquire_lock; then
	log "another run is still in progress; skipping"
	exit 0
fi

if p=$(first_usable_our_mount); then
	clear_failures
	exit 0
fi

our_mounts >"$STATE/.mounts" 2>/dev/null
if [ -s "$STATE/.mounts" ]; then
	# A single failed probe can be a transient stall; confirm before acting.
	sleep 3
	if p=$(first_usable_our_mount); then
		clear_failures
		exit 0
	fi
	force_unmount_ours
fi

attempt=1
while [ "$attempt" -le 3 ]; do
	if mount_share; then
		if wait_mounted "$MOUNTED_PATH"; then
			log "mounted at $MOUNTED_PATH"
			clear_failures
			exit 0
		fi
		MOUNT_ERROR="mount did not become available"
	fi
	attempt=$((attempt + 1))
	if [ "$attempt" -le 3 ]; then
		sleep 5
	fi
done

other=$(share_mounts | /usr/bin/awk -F'|' -v u="$ME" '$2 != "" && $2 != u { print $2; exit }')
if [ -n "$other" ]; then
	bump_failure "share is held by $other (${MOUNT_ERROR:-mount failed})"
else
	bump_failure "${MOUNT_ERROR:-mount did not become available}"
fi
exit 1
