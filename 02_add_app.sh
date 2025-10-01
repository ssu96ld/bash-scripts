#!/usr/bin/env bash
set -euo pipefail

# Adds a Node app with live/dev/staging (optional), pm2, nginx vhosts, TLS, and webhooks appended to the shared webhook server.

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3000

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

APP_USER="${SUDO_USER:-root}"
APP_HOME="$(eval echo ~${APP_USER})"

read -rp "App name (e.g., myapp): " APP_NAME
read -rp "GitHub repository URL: " REPO_URL
read -rp "Development domain (e.g., dev.example.com) or blank: " DEV_DOMAIN
read -rp "Staging domain (e.g., staging.example.com) or blank: " STAGING_DOMAIN
read -rp "Live domain (e.g., example.com): " LIVE_DOMAIN
[[ -z "${APP_NAME}" || -z "${REPO_URL}" || -z "${LIVE_DOMAIN}" ]] && { echo "App name, repo URL, and live domain are required."; exit 1; }

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }
DEV_DOMAIN="$(strip_domain "${DEV_DOMAIN}")"
STAGING_DOMAIN="$(strip_domain "${STAGING_DOMAIN}")"
LIVE_DOMAIN="$(strip_domain "${LIVE_DOMAIN}")"

# nvm in this shell for pm2 operations
export NVM_DIR="$(eval echo ~${APP_USER})/.nvm"; . "$NVM_DIR/nvm.sh" 2>/dev/null || true

# helpers
# Returns the first free TCP port at or above the starting port.
find_free_port() {
  local port="$1"
  while :; do
    # If ss prints nothing, port is free
    if [[ -z "$(ss -H -ltn "sport = :$port")" ]]; then
      echo "$port"
      return
    else
      port=$((port+1))
    fi
  done
}


branch_exists_remote(){ git ls-remote --heads "$1" "$2" | grep -q "refs/heads/$2"; }

# Determine the repo’s default branch (main/master) robustly
DEFAULT_BRANCH="$(
  git ls-remote --symref "${REPO_URL}" HEAD 2>/dev/null \
  | sed -nE 's#^ref: refs/heads/([[:graph:]]+)[[:space:]]+HEAD$#\1#p' \
  | head -n1
)"
if [[ -z "${DEFAULT_BRANCH}" ]]; then
  # Fallback: scan for main/master if the symref approach fails
  DEFAULT_BRANCH="$(git ls-remote "${REPO_URL}" 2>/dev/null | awk -F/ '/refs\/heads\/(main|master)$/ {print $NF; exit}')"
fi
: "${DEFAULT_BRANCH:=main}"


APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"
LIVE_DIR="${APP_DIR_ROOT}/live"
DEV_DIR="${APP_DIR_ROOT}/dev"
STAGING_DIR="${APP_DIR_ROOT}/staging"
mkdir -p "${APP_DIR_ROOT}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR_ROOT}"

clone_branch () {
  local branch="$1" target_dir="$2"
  if [[ -d "${target_dir}/.git" ]]; then
    sudo -u "${APP_USER}" bash -lc "cd '${target_dir}' && git fetch origin '${branch}' && git checkout '${branch}' && git pull origin '${branch}'"
  else
    sudo -u "${APP_USER}" bash -lc "git clone --branch '${branch}' --single-branch '${REPO_URL}' '${target_dir}'"
  fi
}
ensure_branch_exists_remote () {
  local branch="$1"
  if branch_exists_remote "${REPO_URL}" "${branch}"; then return 0; fi
  echo "Attempting to create remote branch '${branch}' from '${DEFAULT_BRANCH}'..."
  local TMP; TMP="$(mktemp -d)"; chown "${APP_USER}:${APP_USER}" "${TMP}"
  sudo -u "${APP_USER}" bash -lc "
    cd '${TMP}'; git clone '${REPO_URL}' repo; cd repo;
    git checkout '${DEFAULT_BRANCH}' && git checkout -b '${branch}' && git push -u origin '${branch}'
  " || echo "WARNING: Could not push '${branch}' (likely no write perms)."
  rm -rf "${TMP}"
}

[[ -n "${DEV_DOMAIN}" ]] && ensure_branch_exists_remote "dev"
[[ -n "${STAGING_DOMAIN}" ]] && ensure_branch_exists_remote "staging"

clone_branch "${DEFAULT_BRANCH}" "${LIVE_DIR}"
if [[ -n "${DEV_DOMAIN}" ]]; then
  if branch_exists_remote "${REPO_URL}" "dev"; then clone_branch "dev" "${DEV_DIR}"
  else sudo -u "${APP_USER}" bash -lc "cp -r '${LIVE_DIR}' '${DEV_DIR}'; cd '${DEV_DIR}'; git checkout -b dev || git checkout dev"; fi
fi
if [[ -n "${STAGING_DOMAIN}" ]]; then
  if branch_exists_remote "${REPO_URL}" "staging"; then clone_branch "staging" "${STAGING_DIR}"
  else sudo -u "${APP_USER}" bash -lc "cp -r '${LIVE_DIR}' '${STAGING_DIR}'; cd '${STAGING_DIR}'; git checkout -b staging || git checkout staging"; fi
fi

# Ports
LIVE_PORT="$(find_free_port "${BASE_PORT}")"
NEXT=$((LIVE_PORT+1)); DEV_PORT="$(find_free_port "${NEXT}")"
NEXT=$((DEV_PORT+1)); STAGING_PORT="$(find_free_port "${NEXT}")"
[[ -z "${DEV_DOMAIN}" ]] && DEV_PORT=""
[[ -z "${STAGING_DOMAIN}" ]] && STAGING_PORT=""

# pm2 configs
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

start_pm2(){
  local dir="$1"
  sudo -u "${APP_USER}" bash -lc "
    export NVM_DIR=\$HOME/.nvm; . \"\$NVM_DIR/nvm.sh\"
    cd '${dir}'; (npm ci || npm install); pm2 start ecosystem.config.js
  "
}
start_pm2 "${LIVE_DIR}"
[[ -n "${DEV_DOMAIN}" ]] && start_pm2 "${DEV_DIR}"
[[ -n "${STAGING_DOMAIN}" ]] && start_pm2 "${STAGING_DIR}"
sudo -u "${APP_USER}" bash -lc "export NVM_DIR=\$HOME/.nvm; . \"\$NVM_DIR/nvm.sh\"; pm2 save"

# nginx vhosts
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

  # Shared deploy webhook (proxied to localhost:${WEBHOOK_PORT})
  location ^~ /_deploy/ {
    proxy_pass http://127.0.0.1:${WEBHOOK_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF
}
make_vhost "${LIVE_DOMAIN}" "${LIVE_PORT}"
[[ -n "${DEV_DOMAIN}" ]] && make_vhost "${DEV_DOMAIN}" "${DEV_PORT}"
[[ -n "${STAGING_DOMAIN}" ]] && make_vhost "${STAGING_DOMAIN}" "${STAGING_PORT}"

nginx -t
systemctl reload nginx

# TLS (issue or reuse)
issue_tls(){
  local domain="$1"
  certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email || \
    echo "WARNING: certbot failed for $domain (try later)."
}
issue_tls "${LIVE_DOMAIN}"
[[ -n "${DEV_DOMAIN}" ]] && issue_tls "${DEV_DOMAIN}"
[[ -n "${STAGING_DOMAIN}" ]] && issue_tls "${STAGING_DOMAIN}"

# Append webhooks for this app
randhex(){ openssl rand -hex 32; }
LIVE_SECRET="$(randhex)"
DEV_SECRET="$(randhex)"
STAGING_SECRET="$(randhex)"

# Build JSON fragments
HOOKS_TO_ADD="[{
  \"id\": \"${APP_NAME}-live\",
  \"path\": \"/_deploy/live\",
  \"secret\": \"${LIVE_SECRET}\",
  \"dir\": \"${LIVE_DIR}\",
  \"branch\": \"${DEFAULT_BRANCH}\",
  \"pm2\": \"${APP_NAME}-live\"
}"
if [[ -n "${DEV_DOMAIN}" ]]; then
  HOOKS_TO_ADD+=",{
    \"id\": \"${APP_NAME}-dev\",
    \"path\": \"/_deploy/dev\",
    \"secret\": \"${DEV_SECRET}\",
    \"dir\": \"${DEV_DIR}\",
    \"branch\": \"dev\",
    \"pm2\": \"${APP_NAME}-dev\"
  }"
fi
if [[ -n "${STAGING_DOMAIN}" ]]; then
  HOOKS_TO_ADD+=",{
    \"id\": \"${APP_NAME}-staging\",
    \"path\": \"/_deploy/staging\",
    \"secret\": \"${STAGING_SECRET}\",
    \"dir\": \"${STAGING_DIR}\",
    \"branch\": \"staging\",
    \"pm2\": \"${APP_NAME}-staging\"
  }"
fi
HOOKS_TO_ADD+="]"

# Merge into hooks.json using a tiny inline Python (no jq dependency)
python3 - "$WEBHOOK_DIR/hooks.json" "$HOOKS_TO_ADD" <<'PY'
import json, sys
cfg_path = sys.argv[1]
new_hooks = json.loads(sys.argv[2])
with open(cfg_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
cfg.setdefault('hooks', [])
# dedupe by id
existing_ids = {h.get('id') for h in cfg['hooks']}
for h in new_hooks:
    if h.get('id') not in existing_ids:
        cfg['hooks'].append(h)
with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)
print("OK")
PY

# Restart webhook process to pick up new routes
sudo -u "${APP_USER}" bash -lc "export NVM_DIR=\$HOME/.nvm; . \"\$NVM_DIR/nvm.sh\"; pm2 restart deploy-webhooks; pm2 save"

echo
echo "================== APP ADDED =================="
echo "App: ${APP_NAME}  Repo: ${REPO_URL}"
echo "Live:   https://${LIVE_DOMAIN}   (PORT ${LIVE_PORT})"
[[ -n "${DEV_DOMAIN}" ]] && echo "Dev:    https://${DEV_DOMAIN}    (PORT ${DEV_PORT})"
[[ -n "${STAGING_DOMAIN}" ]] && echo "Staging:https://${STAGING_DOMAIN} (PORT ${STAGING_PORT})"
echo
echo "Deploy Webhooks (POST with header X-Webhook-Secret):"
echo "  Live:    https://${LIVE_DOMAIN}/_deploy/live       Secret: ${LIVE_SECRET}"
[[ -n "${DEV_DOMAIN}" ]] && echo "  Dev:     https://${DEV_DOMAIN}/_deploy/dev        Secret: ${DEV_SECRET}"
[[ -n "${STAGING_DOMAIN}" ]] && echo "  Staging: https://${STAGING_DOMAIN}/_deploy/staging    Secret: ${STAGING_SECRET}"
echo
echo "Example:"
echo "  curl -X POST https://${LIVE_DOMAIN}/_deploy/live -H 'X-Webhook-Secret: ${LIVE_SECRET}'"
echo "================================================"
