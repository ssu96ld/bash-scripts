#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# 03_add_branch.sh
# - Adds/updates a single repo branch as its own app instance
# - Safe alongside existing live/dev/staging
# - Bootstraps webhook server if missing (idempotent)
# - PM2 config & start
# - Nginx vhost + Certbot
# - Webhook integration:
#     * simple endpoint: /_deploy/<branch> (secret per domain)
#     * GitHub HMAC mapping: refs/heads/<branch> -> this instance
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3100   # base to scan from for feature branches

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~${APP_USER})"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! id -u "$GIT_USER" >/dev/null 2>&1; then
  echo "ERROR: gitdeploy user not found. Run your server setup first."
  exit 1
fi

ensure_nvm_pm2() {
  sudo -u "${APP_USER}" bash -lc '
    if [[ ! -d "$HOME/.nvm" ]]; then
      echo "ERROR: NVM is not installed for '"${APP_USER}"' (run your server setup first)"; exit 1
    fi
    export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
    command -v pm2 >/dev/null 2>&1 || npm i -g pm2
  '
}

git_as_deploy() { sudo -u "${GIT_USER}" bash -lc "$*"; }

# ---------- Preflight ----------
ensure_nvm_pm2

read -rp "App name (e.g., myapp): " APP_NAME
read -rp "GitHub repository URL: " REPO_URL
read -rp "Branch name to deploy (e.g., feature/auth): " BRANCH_NAME
read -rp "Domain for this branch (e.g., auth.dev.example.com): " BRANCH_DOMAIN
[[ -z "${APP_NAME}" || -z "${REPO_URL}" || -z "${BRANCH_NAME}" || -z "${BRANCH_DOMAIN}" ]] && { echo "All fields are required."; exit 1; }

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }
BRANCH_DOMAIN="$(strip_domain "${BRANCH_DOMAIN}")"

APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"
BRANCH_SAFE="$(echo "${BRANCH_NAME}" | sed 's#[^A-Za-z0-9._-]#-#g')"
BRANCH_DIR="${APP_DIR_ROOT}/branches/${BRANCH_SAFE}"
PM2_NAME="${APP_NAME}-branch-${BRANCH_SAFE}"

mkdir -p "${BRANCH_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR_ROOT}"

# --- helpers ---
find_free_port() {
  local port="$1"
  while :; do
    if [[ -z "$(ss -H -ltn "sport = :$port")" ]]; then
      echo "$port"; return
    fi
    port=$((port+1))
  done
}

branch_exists_remote(){
  git_as_deploy "git ls-remote --heads '$1' '$2'" | grep -q "refs/heads/$2"
}


clone_or_pull () {
  local branch="$1" target_dir="$2"

  # Remove if it exists but is not a Git repo
  if [[ -d "${target_dir}" && ! -d "${target_dir}/.git" ]]; then
    echo "Removing non-git directory before cloning: ${target_dir}"
    rm -rf "${target_dir}"
  fi

  mkdir -p "${target_dir}"
  chown -R "${GIT_USER}:${APP_USER}" "${target_dir}"

  if [[ -d "${target_dir}/.git" ]]; then
    echo "Updating existing branch in ${target_dir}"
    git_as_deploy "cd '${target_dir}' && git fetch origin '${branch}' && git checkout '${branch}' && git reset --hard 'origin/${branch}'"
  else
    echo "Cloning branch '${branch}' into ${target_dir}"
    git_as_deploy "git clone --branch '${branch}' --single-branch '${REPO_URL}' '${target_dir}'"
  fi

  chown -R "${APP_USER}:${APP_USER}" "${target_dir}"
}


repo_full_name_from_url () {
  local url="$1" out=""
  if [[ "$url" =~ ^git@github\.com:(.+)/(.+)\.git$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf "%s" "$out"
}
REPO_FULL_NAME="$(repo_full_name_from_url "${REPO_URL}")"

if ! branch_exists_remote "${REPO_URL}" "${BRANCH_NAME}"; then
  echo "ERROR: Remote branch '${BRANCH_NAME}' does not exist on ${REPO_URL}."
  exit 1
fi

# ---------- Ensure webhook server is installed/up-to-date ----------
bash "${SCRIPT_DIR}/setup_webhook_server.sh"

# --- Choose a stable port (persist to file) ---
PORT_FILE="${BRANCH_DIR}/.port"
if [[ -f "${PORT_FILE}" ]]; then
  BRANCH_PORT="$(cat "${PORT_FILE}")"
else
  BRANCH_PORT="$(find_free_port "${BASE_PORT}")"
  echo "${BRANCH_PORT}" > "${PORT_FILE}"
  chown "${APP_USER}:${APP_USER}" "${PORT_FILE}"
fi

# --- Code checkout/update ---
clone_or_pull "${BRANCH_NAME}" "${BRANCH_DIR}"

# --- PM2 ecosystem + .env ---
make_ecosystem(){
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/ecosystem.config.cjs" <<EOF
module.exports = {
  apps: [{
    name: "${name}",
    cwd: "${dir}",
    script: "npm",
    args: "start",
    env: { PORT: "${port}", NODE_ENV: "development" },
    watch: false
  }]
};
EOF
  chown "${APP_USER}:${APP_USER}" "${dir}/ecosystem.config.cjs"
}

make_env(){
  local dir="$1" port="$2"
  [[ -f "${dir}/.env" ]] || { echo -e "PORT=${port}\nNODE_ENV=development" > "${dir}/.env"; chown "${APP_USER}:${APP_USER}" "${dir}/.env"; }
}

make_ecosystem "${BRANCH_DIR}" "${PM2_NAME}" "${BRANCH_PORT}"
make_env "${BRANCH_DIR}" "${BRANCH_PORT}"

start_pm2(){
  local dir="$1"
  sudo -u "${APP_USER}" bash -lc '
    set -e
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    cd "'"${dir}"'"
    npm config set fund false >/dev/null 2>&1 || true
    npm config set audit false >/dev/null 2>&1 || true
    CI=1 npm ci --no-audit --no-fund --unsafe-perm || CI=1 npm install --no-audit --no-fund --unsafe-perm
    pm2 start ecosystem.config.cjs || pm2 restart ecosystem.config.cjs
  '
}
start_pm2 "${BRANCH_DIR}"
sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 save'

# --- Nginx vhost for this branch ---
mkdir -p "${NGINX_CONF_DIR}"
VHOST_PATH="${NGINX_CONF_DIR}/${BRANCH_DOMAIN}.conf"
cat > "${VHOST_PATH}" <<EOF
server {
  listen 80; listen [::]:80;
  server_name ${BRANCH_DOMAIN};

  location / {
    proxy_pass http://127.0.0.1:${BRANCH_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Simple deploy hook (per-domain)
  location ^~ /_deploy/ {
    proxy_pass http://127.0.0.1:${WEBHOOK_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # GitHub Webhooks (HMAC)
  location ^~ /_github/ {
    proxy_pass http://127.0.0.1:${WEBHOOK_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF

nginx -t
systemctl reload nginx

# --- TLS (best-effort) ---
certbot --nginx -d "${BRANCH_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email || echo "WARNING: certbot failed for ${BRANCH_DOMAIN}"

# --- Update hooks.json (upsert) ---
python3 - "$WEBHOOK_DIR/hooks.json" "$APP_NAME" "$REPO_URL" "$REPO_FULL_NAME" "$BRANCH_NAME" "$BRANCH_DIR" "$PM2_NAME" "$BRANCH_DOMAIN" <<'PY'
import json, os, sys, secrets, re
cfg_path, app_name, repo_url, repo_full, branch_name, branch_dir, pm2_name, branch_domain = sys.argv[1:9]

def load():
    with open(cfg_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save(cfg):
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

def parse_owner_repo(url):
    m = re.match(r'^git@github\.com:([^/]+)/([^/]+)\.git$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    m = re.match(r'^https?://github\.com/([^/]+)/([^/.]+)(?:\.git)?$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    return ""

repo_full = repo_full or parse_owner_repo(repo_url)
cfg = load()
cfg.setdefault("hooks", [])
cfg.setdefault("github", [])

def get_or_create_secret():
    return secrets.token_hex(32)

# ----- simple hook: /_deploy/<branch> scoped to host -----
simple_id = f"{app_name}-branch-{re.sub(r'[^A-Za-z0-9._-]', '-', branch_name)}"
simple_path = f"/_deploy/{branch_name}"
simple_entry = None
for h in cfg["hooks"]:
    if h.get("id")==simple_id:
        h.update({"type":"simple","path":simple_path,"host":branch_domain,"dir":branch_dir,"branch":branch_name,"pm2":pm2_name})
        simple_entry = h
        break
if not simple_entry:
    simple_entry = {"type":"simple","id":simple_id,"path":simple_path,"host":branch_domain,"dir":branch_dir,"branch":branch_name,"pm2":pm2_name,"secret":get_or_create_secret()}
    cfg["hooks"].append(simple_entry)

# ----- GitHub HMAC mapping for this repo -----
gh = None
for g in cfg["github"]:
    if repo_full and g.get("repo")==repo_full:
        gh = g; break
# If none exists yet for this repo, create one
if not gh:
    gh = {"id": app_name, "path": "/_github", "secret": get_or_create_secret(), "repo": repo_full or "", "map": {}}
    cfg["github"].append(gh)

gh.setdefault("map", {})
gh["map"][f"refs/heads/{branch_name}"] = { "dir": branch_dir, "pm2": pm2_name, "branch": branch_name }

save(cfg)

# print simple secret and GH secret (for shell)
print(simple_entry.get("secret",""))
print(gh.get("secret",""))
PY

read -r SIMPLE_SECRET || SIMPLE_SECRET=""
read -r GH_SECRET || GH_SECRET=""

# restart webhook server to pick up changes
sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 restart deploy-webhooks; pm2 save'

echo
echo "================== BRANCH ADDED/UPDATED =================="
echo "App: ${APP_NAME}   Repo: ${REPO_URL}"
echo "Branch: ${BRANCH_NAME}"
echo "Dir: ${BRANCH_DIR}"
echo "Domain: https://${BRANCH_DOMAIN}"
echo "PM2: ${PM2_NAME}    PORT ${BRANCH_PORT}"
echo
echo "Manual deploy webhook (POST with X-Webhook-Secret):"
echo "  https://${BRANCH_DOMAIN}/_deploy/${BRANCH_NAME}    Secret: ${SIMPLE_SECRET:-existing}"
echo
echo "GitHub webhook (HMAC verified):"
echo "  Payload URL: https://${BRANCH_DOMAIN}/_github"
echo "  Secret: ${GH_SECRET:-existing}"
echo "  Mapping:"
echo "    refs/heads/${BRANCH_NAME}  → ${BRANCH_DIR}  (pm2: ${PM2_NAME})"
echo "==========================================================="