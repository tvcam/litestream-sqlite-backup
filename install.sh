#!/usr/bin/env bash
# Install litestream + apply config from this repo.
# Run as a user with sudo. Expects litestream.yml and litestream.env to exist in cwd.

set -euo pipefail

LITESTREAM_VERSION="${LITESTREAM_VERSION:-0.5.11}"
DEB="litestream-${LITESTREAM_VERSION}-linux-x86_64.deb"

if [[ ! -f litestream.yml || ! -f litestream.env ]]; then
  echo "error: litestream.yml and litestream.env must exist in cwd"
  echo "       copy from .example and fill in your values"
  exit 1
fi

if ! command -v litestream >/dev/null 2>&1; then
  echo "==> installing litestream ${LITESTREAM_VERSION}"
  cd /tmp
  wget -q "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/${DEB}"
  sudo dpkg -i "${DEB}"
  cd - >/dev/null
fi

echo "==> installing config"
sudo install -m 644 -o root -g root litestream.yml /etc/litestream.yml
sudo install -m 600 -o root -g root litestream.env /etc/litestream.env

echo "==> writing systemd drop-in to source env file"
sudo mkdir -p /etc/systemd/system/litestream.service.d
sudo tee /etc/systemd/system/litestream.service.d/override.conf > /dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/litestream.env
EOF

echo "==> enabling + starting litestream"
sudo systemctl daemon-reload
sudo systemctl enable --now litestream
sleep 3
sudo systemctl status litestream --no-pager | head -15

echo
echo "==> tail with: sudo journalctl -u litestream -f"
