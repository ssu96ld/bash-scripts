#!/usr/bin/env bash
set -euo pipefail

# Idempotent server bootstrap: base packages, gitdeploy user, nvm/Node, pm2, shared webhook service.

DEBIAN_FRONTEND=noninteractive
GIT_USER="gitdeploy"
SHELL_FOR_USERS="/bin/bash"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~${APP_USER})"
NVM_VERSION="v0.39.7"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

# --- Packages ---
apt-get update -y
apt-get install -y curl build-essential git nginx python3-certbot-nginx ufw openssl

# --- Firewall ---
if command -v ufw >/dev/null 2>&1; then
  ufw allow 'Nginx Full' || true
fi

# --- gitdeploy user & SSH key (create if missing) ---
if ! id -u "$GIT_USER" >/dev/null 2>&1; then
  useradd -m -s "$SHELL_FOR_USERS" "$GIT_USER"
fi
install -d -m 700 -o "$GIT_USER" -g "$GIT_USER" "/home/$GIT_USER/.ssh"
if [[ ! -f "/home/$GIT_USER/.ssh/id_ed25519" ]]; then
  sudo -u "$GIT_USER" ssh-keygen -t ed25519 -N "" -C "${GIT_USER}@$(hostname)" -f "/home/$GIT_USER/.ssh/id_ed25519"
  echo
  echo "======== gitdeploy PUBLIC key ========"
  cat "/home/$GIT_USER/.ssh/id_ed25519.pub"
  echo "======================================"
  echo
  echo "======== gitdeploy PRIVATE key ======="
  cat "/home/$GIT_USER/.ssh/id_ed25519"
  echo "======================================"
  echo
else
  echo "gitdeploy user & SSH key already exist (not reprinted)."
fi

# --- nvm + Node LTS + pm2 for APP_USER (skip if present) ---
sudo -u "$APP_USER" bash -lc "
  if [[ ! -d \"\$HOME/.nvm\" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
  fi
  export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"
  if ! command -v node >/dev/null 2>&1; then
    nvm install --lts
    nvm alias default 'lts/*'
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2
  fi
"

# --- Shared webhook server (create once, via helper script) ---
bash "${SCRIPT_DIR}/setup_webhook_server.sh"

echo ""
echo "=========================================="
echo "Server setup complete!"
echo "=========================================="
echo ""
echo "IMPORTANT: You must LOG OUT and LOG BACK IN for nvm/node/npm to be available."
echo "After logging back in, you can run add_app.sh to add apps."
echo ""
