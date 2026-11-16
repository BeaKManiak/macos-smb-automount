# smb-automount

Keep an SMB share mounted in Finder on macOS. A per-user LaunchAgent reuses the
password already saved in your login Keychain and remounts the share after
sleep, network drops, and reboots. No sudo, no stored password.

## Requirements

- macOS 13 or newer
- the share mounted once in Finder with "Remember this password in my keychain"

## Install

```sh
git clone https://github.com/BeaKManiak/macos-smb-automount.git
cd macos-smb-automount
cp config.example.sh config.sh
nano config.sh
sh install.sh
```

`SERVER` is the NAS address, `NAS_USER` is the SMB account, and `SHARE` is the
folder name. Run this once in each macOS account you want the share mounted for.

## Verify

```sh
mount | grep -i smbfs
tail -f ~/Library/Logs/smb-automount.log
```

## Uninstall

```sh
sh install.sh --uninstall
rm -f ~/Library/Logs/smb-automount*.log
```

## Troubleshooting

- `no SMB keychain credential` in the log: connect once via Finder and save the
  password for that account.
- `share is held by …`: another account owns the mount; mounts are not shared.
- Nothing in the log: `launchctl print gui/$(id -u)/local.smb-automount`.

More detail: [docs/how-it-works.md](docs/how-it-works.md).

## License

MIT — see [LICENSE](LICENSE).
