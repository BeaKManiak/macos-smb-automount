# smb-automount configuration.
#
# Copy this file to config.sh and edit it. config.sh is gitignored, so your
# real server and account never end up in the repository.

# SMB server: hostname or IP address.
SERVER="192.168.1.10"

# SMB account name. Leave empty to use an anonymous/guest session.
NAS_USER="nasuser"

# Share name, as listed on the server.
SHARE="share"

# launchd label. Also used as the plist filename.
LABEL="local.smb-automount"

# How often the watchdog runs, in seconds.
INTERVAL=120
