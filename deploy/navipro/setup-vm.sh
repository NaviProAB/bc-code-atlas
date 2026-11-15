#!/usr/bin/env bash
# One-time (and re-runnable) setup of the bc-code-atlas server on an Ubuntu VM.
# Run as root. cloud-init runs it at first boot; run it again after changing a
# unit file or the Caddyfile.
#
#   setup-vm.sh <public-hostname> [github-orgs]
#
# What it leaves behind:
#   /opt/bcatlas/bc-code-atlas     this repository, owned by user bcatlas
#   /etc/bcatlas/gateway.env       gateway settings
#   /etc/bcatlas/service-keys.json hashes of the service keys (see New-ServiceKey.ps1)
#   systemd: bcatlas-{search,graph,registry,build,aggregator}.service under
#            bcatlas.target, plus bcatlas-gateway, bcatlas-firstindex and caddy
set -euo pipefail

HOSTNAME_PUBLIC="${1:?usage: setup-vm.sh <public-hostname> [github-orgs]}"
GITHUB_ORGS="${2:-NaviProAB}"
REPO=/opt/bcatlas/bc-code-atlas
HERE="$REPO/deploy/navipro"
RUN_AS=bcatlas

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git curl ca-certificates build-essential debian-keyring debian-archive-keyring apt-transport-https gnupg
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y -q caddy
fi

echo "==> user and folders"
id "$RUN_AS" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$RUN_AS"
install -d -o "$RUN_AS" -g "$RUN_AS" /opt/bcatlas /var/lib/bcatlas
install -d -m 750 -o root -g "$RUN_AS" /etc/bcatlas
[ -f /etc/bcatlas/service-keys.json ] || { echo '{"services": {}}' > /etc/bcatlas/service-keys.json; }
chown root:"$RUN_AS" /etc/bcatlas/service-keys.json && chmod 640 /etc/bcatlas/service-keys.json

cat > /etc/bcatlas/gateway.env <<EOF
ATLAS_UPSTREAM=http://127.0.0.1:8800
ATLAS_GITHUB_ORGS=$GITHUB_ORGS
ATLAS_SERVICE_KEYS_FILE=/etc/bcatlas/service-keys.json
ATLAS_GATEWAY_HOST=127.0.0.1
ATLAS_GATEWAY_PORT=8790
EOF
chown root:"$RUN_AS" /etc/bcatlas/gateway.env && chmod 640 /etc/bcatlas/gateway.env

echo "==> uv"
sudo -u "$RUN_AS" -H bash -c 'command -v ~/.local/bin/uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh'

echo "==> python environments"
sudo -u "$RUN_AS" -H bash -euo pipefail -c "
  export PATH=\$HOME/.local/bin:\$PATH
  cd '$REPO'
  git submodule update --init --recursive --force
  git -C data/docs sparse-checkout init --cone && git -C data/docs sparse-checkout set business-central
  git -C data/docs-devitpro sparse-checkout init --cone && git -C data/docs-devitpro sparse-checkout set dev-itpro/developer
  for p in tools/cocoindex-code chunker aggregator registry build deploy/navipro/gateway; do uv sync --project \"\$p\"; done
  uv sync --project tools/graphify-al --extra al --extra mcp
  mkdir -p ~/.cocoindex_code
  cat > ~/.cocoindex_code/global_settings.yml <<'YML'
provider: sentence-transformers
model: ibm-granite/granite-embedding-97m-multilingual-r2
device: cpu
YML
"

echo "==> systemd and caddy"
install -m 644 "$HERE"/systemd/*.service "$HERE"/systemd/*.target /etc/systemd/system/
sed "s/__HOSTNAME__/$HOSTNAME_PUBLIC/" "$HERE/Caddyfile" > /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable bcatlas.target bcatlas-gateway.service bcatlas-firstindex.service caddy
systemctl restart caddy bcatlas-gateway.service

# The first index takes hours on CPU. It runs in the background as its own
# unit and starts bcatlas.target when it is done; until then the gateway
# answers 502. Follow it with: journalctl -fu bcatlas-firstindex
systemctl start --no-block bcatlas-firstindex.service
echo "==> setup complete; indexing continues in bcatlas-firstindex.service"
