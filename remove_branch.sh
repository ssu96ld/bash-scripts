#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# remove_branch.sh
# - Removes a single branch deployment:
#   * PM2 app
#   * Nginx vhost (+best-effort cert removal)
#   * Webhook entries in /opt/deploy-webhooks/hooks.json
#   * Branch directory under /var/www/<app>/branches/<branch>
# - Safe to run multiple times (idempotent)
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000  # not strictly needed here, but left for parity

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~${APP_USER})"

ensure_nvm_pm2() {
  sudo -u "${APP_USER}" bash -lc '
    if [[ ! -d "$HOME/.nvm" ]]; then
      echo "ERROR: NVM is not installed for '"${APP_USER}"'"; exit 1
    fi
    export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
    command -v pm2 >/dev/null 2>&1 || npm i -g pm2
  '
}

# -------- Inputs --------
read -rp "App name (e.g., myapp): " APP_NAME
read -rp "Branch name to remove (e.g., feature/auth): " BRANCH_NAME
read -rp "Domain for this branch (e.g., auth.dev.example.com): " BRANCH_DOMAIN
read -rp "GitHub repository URL (optional, limits GH mapping removal): " REPO_URL || true

[[ -z "${APP_NAME}" || -z "${BRANCH_NAME}" || -z "${BRANCH_DOMAIN}" ]] && { echo "App name, branch name, and domain are required."; exit 1; }

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }
BRANCH_DOMAIN="$(strip_domain "${BRANCH_DOMAIN}")"

BRANCH_SAFE="$(echo "${BRANCH_NAME}" | sed 's#[^A-Za-z0-9._-]#-#g')"
BRANCH_DIR="${WWW_ROOT}/${APP_NAME}/branches/${BRANCH_SAFE}"
PM2_NAME="${APP_NAME}-branch-${BRANCH_SAFE}"
VHOST_PATH="${NGINX_CONF_DIR}/${BRANCH_DOMAIN}.conf"

# -------- Helpers --------
ensure_nvm_pm2

repo_full_name_from_url () {
  local url="$1" out=""
  if [[ "$url" =~ ^git@github\.com:(.+)/(.+)\.git$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf "%s" "$out"
}
REPO_FULL_NAME=""
if [[ -n "${REPO_URL:-}" ]]; then
  REPO_FULL_NAME="$(repo_full_name_from_url "${REPO_URL}")"
fi

# -------- Remove PM2 process (best-effort) --------
sudo -u "${APP_USER}" bash -lc '
  export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
  if pm2 list | grep -q "'"${PM2_NAME}"'"; then
    pm2 delete "'"${PM2_NAME}"'" || true
    pm2 save
  fi
' || true

# -------- Remove Nginx vhost (best-effort) --------
if [[ -f "${VHOST_PATH}" ]]; then
  rm -f "${VHOST_PATH}"
  nginx -t && systemctl reload nginx || echo "WARNING: nginx reload failed; check config."
fi

# -------- Remove TLS cert (best-effort) --------
if command -v certbot >/dev/null 2>&1; then
  # This only works if the cert name matches the domain; if not, user can remove manually.
  certbot delete --cert-name "${BRANCH_DOMAIN}" --non-interactive || true
fi

# -------- Update webhook config --------
if [[ -f "${WEBHOOK_DIR}/hooks.json" ]]; then
  python3 - "$WEBHOOK_DIR/hooks.json" "$APP_NAME" "$BRANCH_NAME" "$REPO_FULL_NAME" <<'PY'
import json, os, sys, re
cfg_path, app_name, branch_name, repo_full = sys.argv[1:5]

def load():
    with open(cfg_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save(cfg):
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

cfg = load()
cfg.setdefault("hooks", [])
cfg.setdefault("github", [])

# Remove simple hook by id
safe = re.sub(r'[^A-Za-z0-9._-]', '-', branch_name)
simple_id = f"{app_name}-branch-{safe}"
cfg["hooks"] = [h for h in cfg["hooks"] if h.get("id") != simple_id]

# Remove GH mapping: either from a specific repo (if provided) or from all repos
ref_key = f"refs/heads/{branch_name}"
for g in list(cfg["github"]):
    if repo_full and g.get("repo") != repo_full:
        continue
    m = g.get("map") or {}
    if ref_key in m:
        m.pop(ref_key, None)
        g["map"] = m
    # Do NOT delete the repo entry entirely; it may still map other branches

save(cfg)
PY

  # Restart webhook server if present
  if [[ -f "${WEBHOOK_DIR}/server.js" ]]; then
    sudo -u "${APP_USER}" bash -lc '
      export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
      if pm2 list | grep -q "deploy-webhooks"; then
        pm2 restart deploy-webhooks
        pm2 save
      fi
    ' || true
  fi
fi

# -------- Remove branch directory (best-effort) --------
if [[ -d "${BRANCH_DIR}" ]]; then
  rm -rf "${BRANCH_DIR}"
fi

echo
echo "================== BRANCH REMOVED =================="
echo "App: ${APP_NAME}"
echo "Branch: ${BRANCH_NAME}"
echo "Domain: ${BRANCH_DOMAIN}"
echo "PM2: ${PM2_NAME}"
echo "Dir removed (if existed): ${BRANCH_DIR}"
echo "Vhost removed (if existed): ${VHOST_PATH}"
echo "Webhook entries cleaned from: ${WEBHOOK_DIR}/hooks.json"
echo "===================================================="
