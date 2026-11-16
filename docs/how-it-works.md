# How it works

## Pieces

- `mount-share.sh` — the whole runtime. Installed per user.
- `install.sh` — copies the script and config into the user's home and loads a
  LaunchAgent. No sudo.
- `local.smb-automount.plist.template` — rendered to
  `~/Library/LaunchAgents/<LABEL>.plist`.
- `config.sh` — three required values (`SERVER`, `NAS_USER`, `SHARE`).

Per-user paths:

```
~/Library/LaunchAgents/local.smb-automount.plist
~/Library/Application Support/smb-automount/mount-share.sh
~/Library/Application Support/smb-automount/config.sh
~/Library/Application Support/smb-automount/failures
~/Library/Logs/smb-automount.log
~/Library/Logs/smb-automount.err.log
```

The old version installed into `/Library` and shared one config between all
accounts. That meant one account's install silently changed every other
account's share. This version keeps every input per user: Keychain, config,
state, and log.

## Flow

```
launchd (login + every INTERVAL seconds)
        │
        ▼
mount-share.sh
        │
        ├─ credential in Keychain? ──no──▶ log once, exit silently
        │
        ├─ lock held by another run? ──yes──▶ exit
        │
        ├─ a mount of this share owned by me, healthy? ──yes──▶ exit
        │
        ├─ my mount exists but is stale? ──▶ probe again, then force-unmount
        │
        └─ osascript "mount volume smb://…" ──▶ verify the returned path
                                                 (up to 20 s, 3 attempts)
```

## Details that matter

**Mounting uses AppleScript `mount volume`, not `mount_smbfs`.** That routes
through NetAuthAgent, which reuses the Keychain item Finder saved. The password
is never stored in the repository or in the script.

**The Keychain check never asks for the secret.** `security
find-internet-password` without `-w` reads attributes only. Asking for the
secret would block on a GUI prompt and hang the agent. The lookup is restricted
to SMB items (`-r 'smb '`); a saved web password for the same host does not
count.

**Health is checked with `stat`, not `ls`.** macOS TCC blocks background agents
from reading network volume *contents*, but metadata calls are allowed. A hung
SMB session makes `stat` hang too, which is why it is wrapped in a timeout.

**Ownership is part of health.** `stat` alone would accept another user's
`d--x--x--x` mountpoint as healthy. The script compares the volume owner to the
current user, so another account's mount is never treated as usable.

**Share matching is exact and case-insensitive.** `download` must not match
`downloads`. Spaces in mount output arrive as `\040` and are normalized before
comparison. Guest sessions also match the `//guest@host/share` form.

**Every mount is considered, not just the first one.** macOS happily creates
`/Volumes/share-2` for a second mount of the same share (including by the same
user after a race). All mounts owned by the current user are enumerated; stale
ones are removed before remounting.

**`mount volume` is asynchronous and returns a path.** It returns before the
volume is usable, so the script polls the returned path (and any mount of this
share owned by the user) for up to 20 seconds.

**A single failed probe is retried once after 3 seconds** before a mount is
declared stale, to avoid force-unmounting on a momentary stall.

**Runs are serialized with a lock.** `RunAtLoad`, `StartInterval`, and a manual
`launchctl kickstart` can otherwise overlap. The lock records its PID; if the
recorded process is gone (for example after `kickstart -k`), the next run clears
the lock immediately instead of waiting for a timeout.

**Retries the mount 3 times, 5 seconds apart**, so a network that is still
coming up at login does not cost a full interval.

**Failures back off quietly.** After 3 consecutive failures the agent posts one
notification, then keeps retrying without repeating it.

## macOS gotchas

**`HOME` is not always set for launchd jobs.** A script that writes to
`$HOME/...` can silently fail. The script derives `HOME` with `dscl` when it is
empty.

**TCC blocks directory listings on network volumes** for background agents.
`ls /Volumes/share` returns *Operation not permitted* even though the mount is
fine. `stat` on the mount point is allowed.

**Fast User Switching leaves background sessions running.** Their agents keep
working, and their mounts remain owned by them. Don't expect to reuse another
account's mount.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No mount; log says `no SMB keychain credential` | No Keychain entry for this account | Connect once via Finder and save the password |
| No mount and no log at all | Agent not loaded, or loaded for another account | `launchctl print gui/$(id -u)/local.smb-automount` |
| `share is held by …` or `File exists` | Another account owns the mount | Log that account out; mounts are private to their owner |
| `Operation not permitted` on the volume | TCC blocks background volume listings | Use Finder; the agent probes with `stat` |
| Mount stays stale after sleep or a network drop | Dead SMB session | The agent force-unmounts and remounts; or `diskutil unmount force /Volumes/<share>` |
| Agent stuck at `state = running` | Hung probe or `osascript` | `launchctl bootout` then `launchctl bootstrap` the agent |

The log is the reliable record. Notifications are best-effort and depend on
Notification Center settings.

## Upgrading from the old system-wide install

The first version installed into `/Library` and shared one config between all
accounts. Remove it before installing this version.

In each logged-in account:

```sh
launchctl bootout gui/$(id -u)/local.smb-automount 2>/dev/null
launchctl bootout gui/$(id -u)/local.smb-automount.download 2>/dev/null
```

Then once as an administrator:

```sh
sudo rm -f /Library/LaunchAgents/*smb-automount*.plist
sudo rm -rf "/Library/Application Support/smb-automount"
```

Then follow the README install steps. Your old runtime state lives in
`~/Library/Application Support/smb-automount`; remove it too for a clean slate.

## Known limitations

- One share per user, one config per account. Multiple shares would need one
  label and one config directory per share.
- Finder's "Reconnect at login" can race the agent and create duplicate
  mountpoints. Leave it off and let the agent do the mounting.
- Discovery is not fixed. If the server is on another subnet behind NAT, it will
  not appear in Finder → Network.
- If another account owns a mount, macOS may allow a second one at
  `/Volumes/share-2`. If the mount attempt fails, the agent logs the owner and
  backs off.
