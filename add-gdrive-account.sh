#!/usr/bin/env bash
# add-gdrive-account.sh <name> — add ANOTHER Google Drive account (another rclone
# remote + its own auto-mounted folder), e.g.:
#
#   ./add-gdrive-account.sh work     # → remote 'gdrive-work:', mounted at ~/Drive-work
#
# A Google sign-in window opens: sign in with the account you want for THIS drive
# (use "Use another account" in the chooser if needed) and click Allow.
#
# Repeatable for as many accounts as you like. Remove one with:
#   systemctl --user disable --now rclone-gdrive-<name> && rm ~/.config/systemd/user/rclone-gdrive-<name>.service
#   rclone config delete gdrive-<name>

set -euo pipefail

RCLONE="${RCLONE:-$HOME/.local/bin/rclone}"
name="${1:-}"
[[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "usage: $0 <short-name>  (e.g. work)"; exit 1; }
[[ -x $RCLONE ]] || { echo "rclone not found at $RCLONE"; exit 1; }

remote="gdrive-$name"
dir="$HOME/Drive-$name"
unit="$HOME/.config/systemd/user/rclone-gdrive-$name.service"

echo "==> Creating remote '$remote' (scope: drive)"
"$RCLONE" config create "$remote" drive scope drive --non-interactive >/dev/null

echo "==> A browser window will open — sign in with the NEW Google account and click Allow."
printf 'y\ny\nn\n' | "$RCLONE" config reconnect "$remote:"

mkdir -p "$dir"
cat > "$unit" <<EOF
[Unit]
Description=Google Drive '$remote' via rclone (mounted at $dir)
After=network-online.target

[Service]
ExecStart=$RCLONE mount $remote: $dir --vfs-cache-mode writes --dir-cache-time 12h
ExecStop=/bin/fusermount3 -uz $dir
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "rclone-gdrive-$name.service"
sleep 4

if findmnt "$dir" >/dev/null; then
    echo "==> OK: $remote: mounted at $dir"
    timeout 60 "$RCLONE" about "$remote:" 2>/dev/null | head -2 || true
    echo "==> Files visible in Dolphin under Home → Drive-$name"
else
    echo "==> Mount failed — check: journalctl --user -u rclone-gdrive-$name -e" >&2
    exit 1
fi
