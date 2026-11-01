# smb-automount (macOS)

Keep an SMB share mounted at login on macOS, so it is already there in Finder → Locations when you start working — no **Go → Connect to Server** every morning.

A system-wide LaunchAgent mounts the share for every user session, reuses the credential already stored in the login Keychain, and keeps it mounted across sleep, network drops and server reboots.

---

## Why this exists

Two things go wrong on a fresh login:

1. **Nothing mounts the share.** macOS has no built-in "mount this SMB share at login" option, and `/etc/fstab` is not a supported path for SMB.
2. **Finder → Network may never discover the server.** If the NAS sits on a different subnet from the Mac — for example behind a second router doing NAT — mDNS/Bonjour does not cross that boundary and the server never shows up on its own.

This agent solves the first problem, which is the one you actually notice. See [Limitations](#limitations) for the second.

---

## How it works

```
launchd (login + every INTERVAL seconds)
        │
        ▼
mount-share.sh
        │
        ├─ credential in Keychain? ──no──▶ exit silently
        │
        ├─ already mounted and healthy? ──yes──▶ exit
        │
        ├─ mounted but stale and ours? ──▶ diskutil unmount force
        │
        ├─ mounted by another user? ──▶ back off (macOS forbids a second mount)
        │
        └─ osascript "mount volume smb://…" ──▶ poll until usable
```

Key details:

- **Mounting uses AppleScript `mount volume`**, not `mount_smbfs`. That routes through NetAuthAgent, which reuses the Keychain item Finder already saved. The password is never stored in this repository or in the script.
- **Health is checked with `stat`, not `ls`.** macOS TCC blocks background agents from reading network volume *contents*, but metadata calls are allowed.
- **`mount volume` returns before the volume is ready**, so the script polls for up to 20 seconds before declaring success.
- **A failed probe is retried once after 3 seconds** before a mount is declared stale, to avoid force-unmounting on a momentary stall.
- **Never touches a mount owned by another user.** Mounts are system-wide and owned by whoever created them.
- **Retries the mount 3 times, 5 seconds apart**, so a network that is still coming up at login does not cost you a full interval.

---

## Requirements

- macOS 13 or newer (tested on macOS 27.2, Apple silicon).
- An SMB share you can already mount through Finder.
- The credential saved in the login Keychain — connect once via Finder and tick "Remember this password in my keychain".
- Administrator rights for the one-time install.

---

## Install

```sh
git clone https://github.com/<you>/macos-smb-automount.git
cd macos-smb-automount

cp config.example.sh config.sh
$EDITOR config.sh          # set SERVER, NAS_USER, SHARE

sudo sh install.sh
launchctl bootstrap gui/$(id -u) "/Library/LaunchAgents/local.smb-automount.plist"
```

`config.sh` is gitignored, so your real server and account never get committed.

---

## Configuration

| Variable | Meaning | Example |
|---|---|---|
| `SERVER` | SMB host or IP | `192.168.1.10` |
| `NAS_USER` | SMB account; empty for guest | `nasuser` |
| `SHARE` | Share name | `share` |
| `LABEL` | launchd label and plist filename | `local.smb-automount` |
| `INTERVAL` | Watchdog period in seconds | `120` |

After editing, reinstall and reload:

```sh
sudo sh install.sh
launchctl bootout gui/$(id -u)/local.smb-automount 2>/dev/null
launchctl bootstrap gui/$(id -u) "/Library/LaunchAgents/local.smb-automount.plist"
```

---

## Verify

```sh
# Is it mounted?
mount | grep -i share

# Is the agent loaded, and what was its last exit code?
launchctl print gui/$(id -u)/local.smb-automount | grep -E 'state|last exit code|run interval'

# Run it now
launchctl kickstart -k gui/$(id -u)/local.smb-automount

# Watch what it does
tail -f ~/Library/Logs/smb-automount.log
```

End-to-end test:

```sh
diskutil unmount /Volumes/share
launchctl kickstart -k gui/$(id -u)/local.smb-automount
sleep 10
mount | grep -i share
```

Expected: a `mounted at /Volumes/share` line in the log and exit code `0`.

> Finder may remount the share on its own within a few seconds of an unmount. If the log stays empty, the agent found it already mounted — that is success, not a failure.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Share never appears | No Keychain credential for this account | Connect once through Finder with "Remember this password" |
| `share held by … not accessible` | Another logged-in user owns the mount | Log that user out; macOS will not mount the same share twice |
| `mount_smbfs: File exists` | Same as above | Same |
| Agent stuck at `state = running` | A hung probe or `osascript` | `launchctl bootout` then `launchctl bootstrap` the agent |
| `Operation not permitted` on the volume | TCC blocks background agents from listing network volume contents | Use `stat`/`df` in probes, never `ls` |
| Mount exists but is stale | SMB session died (network drop, server reboot) | The agent force-unmounts and remounts; manually: `diskutil unmount force /Volumes/share` |
| Nothing in the log at all | `HOME` empty under launchd, or the agent is not loaded | Check `launchctl print`; the script derives `HOME` itself |
| Notification never appears | Notifications disabled for the agent | The log is the reliable record |

Three problems are worth calling out because they are not obvious:

**`HOME` is empty for system-wide LaunchAgents.** A script that writes to `$HOME/...` silently fails or writes to `/Library/...`. Derive it with `dscl`.

**TCC blocks directory listings on network volumes** for background agents. `ls /Volumes/share` returns *Operation not permitted* even though the mount is fine. `stat` on the mount point is allowed and still hangs on a dead session, so it is the right probe.

**`mount volume` is asynchronous.** It returns before the volume is usable. Poll the mount table and `stat` the mount point before treating the mount as done.

---

## Limitations

- **Discovery is not fixed.** If the server is on another subnet behind NAT, it will not appear in Finder → Network. Move it onto the same L2 network as the Mac, or put the intervening router into access-point mode. This agent makes that invisible in practice, but it does not make mDNS cross a NAT.
- **One mount per share, system-wide.** macOS returns `File exists` if the same share is mounted twice, even at a different mount point. With fast user switching, the second user's agent backs off; the mount is also owned by the first user (`drwx------`), so the second user could not use it anyway.
- **One credential per user.** Each account needs its own Keychain entry. Accounts without one are skipped silently.
- **Wired path can disappear.** If the Mac's Ethernet comes from a dock or monitor, powering it off drops the interface; Wi-Fi may take over but the SMB session dies and needs the watchdog to remount.

---

## Uninstall

```sh
launchctl bootout gui/$(id -u)/local.smb-automount 2>/dev/null
sudo rm -f "/Library/LaunchAgents/local.smb-automount.plist"
sudo rm -rf "/Library/Application Support/smb-automount"
rm -rf "$HOME/Library/Application Support/smb-automount" "$HOME/Library/Logs/smb-automount.log"
```

---

## License

MIT — see [LICENSE](LICENSE).
