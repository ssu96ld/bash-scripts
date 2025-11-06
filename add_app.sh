#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)" >&2' ERR

# ===========================================
# 02_add_app.sh
# - Adds/updates a Node app (live/dev/staging)
# - Git access via gitdeploy user
# - App ownership and PM2 processes under ubuntu
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3000

# Users
GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-ubuntu}"
APP_HOME="$(eval echo ~${APP_USER})"
GIT_HOME="/home/${GIT_USER}"

# ---- preflight ----
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)"
  exit 1
fi
if ! id -u "$GIT_USER" >/dev/null 2>&1; then
  echo "ERROR: gitdeploy user not found. Run 01_setup_server.sh first."
  exit 1
fi

# ---- NVM + PM2 check for APP_USER ----
ensure_nvm_pm2() {
  sudo -u "${APP_USER}" bash -lc '
    if [[ ! -d "$HOME/.nvm" ]]; then
      echo "ERROR: NVM is not installed for '"${APP_USER}"' (run 01_setup_server.sh first)"
      exit 1
    fi
    export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
    command -v pm2 >/dev/null 2>&1 || npm i -g pm2
  '
}
ensure_nvm_pm2

# ---- Input ----
read -rp "App name (e.g., myapp): " APP_NAME
read -rp "GitHub repository URL: " REPO_URL
read -rp "Development domain (e.g., dev.example.com) or blank: " DEV_DOMAIN
read -rp "Staging domain (e.g., staging.example.com) or blank: " STAGING_DOMAIN
read -rp "Live domain (e.g., example.com): " LIVE_DOMAIN
[[ -z "${APP_NAME}" || -z "${REPO_URL}" || -z "${LIVE_DOMAIN}" ]] && {
  echo "App name, repo URL, and live domain are required."
  exit 1
}

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }
DEV_DOMAIN="$(strip_domain "${DEV_DOMAIN}")"
STAGING_DOMAIN="$(strip_domain "${STAGING_DOMAIN}")"
LIVE_DOMAIN="$(strip_domain "${LIVE_DOMAIN}")"

# ---- Git helpers (run as gitdeploy) ----
git_as_deploy() { sudo -u "${GIT_USER}" bash -lc "$*"; }

branch_exists_remote() {
  git_as_deploy "git ls-remote --heads '${REPO_URL}' '${1}'" | grep -q "refs/heads/${1}"
}

# Detect default branch
DEFAULT_BRANCH="$(
  git_as_deploy "git ls-remote --symref '${REPO_URL}' HEAD 2>/dev/null" \
  | sed -nE 's#^ref: refs/heads/([[:graph:]]+)[[:space:]]+HEAD$#\1#p' \
  | head -n1
)"
if [[ -z "${DEFAULT_BRANCH}" ]]; then
  DEFAULT_BRANCH="$(git_as_deploy "git ls-remote '${REPO_URL}' 2>/dev/null" | awk -F/ '/refs\/heads\/(main|master)$/ {print $NF; exit}')"
fi
: "${DEFAULT_BRANCH:=main}"

# ---- Dir structure ----
APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"
LIVE_DIR="${APP_DIR_ROOT}/live"
DEV_DIR="${APP_DIR_ROOT}/dev"
STAGING_DIR="${APP_DIR_ROOT}/staging"
mkdir -p "${APP_DIR_ROOT}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR_ROOT}"

# ---- Branch management ----
ensure_branch_exists_remote() {
  local branch="$1"
  if branch_exists_remote "${branch}"; then return 0; fi
  echo "Creating remote branch '${branch}' from '${DEFAULT_BRANCH}'..."
  local TMP; TMP="$(mktemp -d)"
  chown "${GIT_USER}:${GIT_USER}" "${TMP}"
  git_as_deploy "
    cd '${TMP}';
    git clone '${REPO_URL}' repo;
    cd repo;
    git checkout '${DEFAULT_BRANCH}' &&
    git checkout -b '${branch}' &&
    git push -u origin '${branch}'
  " || echo "WARNING: Could not push '${branch}' (likely no write permissions)."
  rm -rf "${TMP}"
}

[[ -n "${DEV_DOMAIN}" ]] && ensure_branch_exists_remote "dev"
[[ -n "${STAGING_DOMAIN}" ]] && ensure_branch_exists_remote "staging"

# ---- Clone or update ----
clone_or_pull() {
  local branch="$1" target_dir="$2"
  mkdir -p "${target_dir}"
  chown -R "${GIT_USER}:${APP_USER}" "${target_dir}"
  if [[ -d "${target_dir}/.git" ]]; then
    git_as_deploy "cd '${target_dir}' && git fetch origin '${branch}' && git checkout '${branch}' && git pull origin '${branch}'"
  else
    git_as_deploy "git clone --branch '${branch}' --single-branch '${REPO_URL}' '${target_dir}'"
  fi
  chown -R "${APP_USER}:${APP_USER}" "${target_dir}"
}

clone_or_pull "${DEFAULT_BRANCH}" "${LIVE_DIR}"
[[ -n "${DEV_DOMAIN}" ]] && clone_or_pull "dev" "${DEV_DIR}"
[[ -n "${STAGING_DOMAIN}" ]] && clone_or_pull "staging" "${STAGING_DIR}"

# ---- Port assignment ----
find_free_port() {
  local port="$1"
  while :; do
    if [[ -z "$(ss -H -ltn "sport = :$port")" ]]; then
      echo "$port"; return
    fi
    port=$((port+1))
  done
}

LIVE_PORT="$(find_free_port "${BASE_PORT}")"
NEXT=$((LIVE_PORT+1)); DEV_PORT="$(find_free_port "${NEXT}")"
NEXT=$((DEV_PORT+1)); STAGING_PORT="$(find_free_port "${NEXT}")"
[[ -z "${DEV_DOMAIN}" ]] && DEV_PORT=""
[[ -z "${STAGING_DOMAIN}" ]] && STAGING_PORT=""

# ---- PM2 ecosystem ----
make_ecosystem(){
  local dir="$1" name="$2" port="$3" env="$4"
  cat > "${dir}/ecosystem.config.js" <<EOF
module.exports = { apps: [{ name: "${name}", cwd: "${dir}", script: "npm", args: "start", env: { PORT: "${port}", NODE_ENV: "${env}" }, watch: false }] };
EOF
  chown "${APP_USER}:${APP_USER}" "${dir}/ecosystem.config.js"
}
make_env(){
  local dir="$1" port="$2" env="$3"
  [[ -f "${dir}/.env" ]] || { echo -e "PORT=${port}\nNODE_ENV=${env}" > "${dir}/.env"; chown "${APP_USER}:${APP_USER}" "${dir}/.env"; }
}

make_ecosystem "${LIVE_DIR}" "${APP_NAME}-live" "${LIVE_PORT}" "production"; make_env "${LIVE_DIR}" "${LIVE_PORT}" "production"
[[ -n "${DEV_DOMAIN}" ]] && { make_ecosystem "${DEV_DIR}" "${APP_NAME}-dev" "${DEV_PORT}" "development"; make_env "${DEV_DIR}" "${DEV_PORT}" "development"; }
[[ -n "${STAGING_DOMAIN}" ]] && { make_ecosystem "${STAGING_DIR}" "${APP_NAME}-staging" "${STAGING_PORT}" "staging"; make_env "${STAGING_DIR}" "${STAGING_PORT}" "staging"; }

# ---- Start PM2 ----
start_pm2(){
  local dir="$1"
  sudo -u "${APP_USER}" bash -lc '
    set -e
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    cd "'"${dir}"'"
    npm config set fund false >/dev/null 2>&1 || true
    npm config set audit false >/dev/null 2>&1 || true
    CI=1 npm ci --no-audit --no-fund --unsafe-perm || CI=1 npm install --no-audit --no-fund --unsafe-perm
    pm2 start ecosystem.config.js || pm2 restart ecosystem.config.js
  '
}

start_pm2 "${LIVE_DIR}"
[[ -n "${DEV_DOMAIN}" ]] && start_pm2 "${DEV_DIR}"
[[ -n "${STAGING_DOMAIN}" ]] && start_pm2 "${STAGING_DIR}"

sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 save'

# ---- Nginx + TLS ----
mkdir -p "${NGINX_CONF_DIR}"
make_vhost(){
  local domain="$1" port="$2"
  cat > "${NGINX_CONF_DIR}/${domain}.conf" <<EOF
server {
  listen 80; listen [::]:80;
  server_name ${domain};

  location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location ^~ /_deploy/ { proxy_pass http://127.0.0.1:${WEBHOOK_PORT}; }
  location ^~ /_github/ { proxy_pass http://127.0.0.1:${WEBHOOK_PORT}; }
}
EOF
}
make_vhost "${LIVE_DOMAIN}" "${LIVE_PORT}"
[[ -n "${DEV_DOMAIN}" ]] && make_vhost "${DEV_DOMAIN}" "${DEV_PORT}"
[[ -n "${STAGING_DOMAIN}" ]] && make_vhost "${STAGING_DOMAIN}" "${STAGING_PORT}"

nginx -t
systemctl reload nginx

issue_tls(){ local d="$1"; certbot --nginx -d "$d" --non-interactive --agree-tos --register-unsafely-without-email || echo "WARNING: certbot failed for $d"; }
issue_tls "${LIVE_DOMAIN}"
[[ -n "${DEV_DOMAIN}" ]] && issue_tls "${DEV_DOMAIN}"
[[ -n "${STAGING_DOMAIN}" ]] && issue_tls "${STAGING_DOMAIN}"

# ---- Webhook integration ----
install_or_upgrade_webhook_server() {
  mkdir -p "${WEBHOOK_DIR}"
  # (webhook server setup unchanged – keep your existing logic here)
}
install_or_upgrade_webhook_server

# (hooks.json Python section unchanged)

echo
echo "================== APP ADDED/UPDATED =================="
echo "App: ${APP_NAME}"
echo "Repo: ${REPO_URL} (branch: ${DEFAULT_BRANCH})"
echo "Live:    https://${LIVE_DOMAIN} (PORT ${LIVE_PORT})"
[[ -n "${DEV_DOMAIN}" ]] && echo "Dev:     https://${DEV_DOMAIN} (PORT ${DEV_PORT})"
[[ -n "${STAGING_DOMAIN}" ]] && echo "Staging: https://${STAGING_DOMAIN} (PORT ${STAGING_PORT})"
echo "========================================================"
