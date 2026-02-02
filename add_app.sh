#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)" >&2' ERR

# ===========================================
# 02_add_app.sh
# - Adds/updates a Node app (live/dev/staging)
# - Git access via gitdeploy user
# - App ownership and PM2 processes under APP_USER (logged-in sudo user)
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3000

# Users
GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~${APP_USER})"
GIT_HOME="/home/${GIT_USER}"
SSH_DIR="${GIT_HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ---- SSH Deploy Key Setup ----
setup_deploy_key() {
  local app_name="$1"
  local repo_url="$2"
  local key_path="${SSH_DIR}/deploykey_${app_name}"
  local ssh_host_alias="${app_name}-github"
  
  # Create .ssh directory if it doesn't exist
  mkdir -p "${SSH_DIR}"
  chown "${GIT_USER}:${GIT_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"
  
  # Generate SSH key if it doesn't exist
  if [[ ! -f "${key_path}" ]]; then
    echo "🔑 Generating SSH deploy key for ${app_name}..." >&2
    sudo -u "${GIT_USER}" ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "deploykey-${app_name}" -q
    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"
  else
    echo "✓ SSH deploy key for ${app_name} already exists" >&2
  fi
  
  # Extract github.com hostname from repo URL
  local github_host="github.com"
  if [[ "$repo_url" =~ github\.com ]]; then
    github_host="github.com"
  fi
  
  # Update SSH config to map the alias to github.com with this specific key
  local config_block="# Deploy key for ${app_name}
Host ${ssh_host_alias}
  HostName ${github_host}
  User git
  IdentityFile ${key_path}
  IdentitiesOnly yes
"
  
  # Create or update SSH config
  touch "${SSH_CONFIG}"
  chown "${GIT_USER}:${GIT_USER}" "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
  
  # Remove old config block for this app if it exists
  if grep -q "# Deploy key for ${app_name}" "${SSH_CONFIG}"; then
    # Remove the old block (from the comment line to the blank line after)
    sudo -u "${GIT_USER}" sed -i.bak "/# Deploy key for ${app_name}/,/^$/d" "${SSH_CONFIG}"
  fi
  
  # Append new config block
  echo "${config_block}" | sudo -u "${GIT_USER}" tee -a "${SSH_CONFIG}" >/dev/null
  
  # Return the SSH host alias and key path for use in git URLs
  echo "${ssh_host_alias}|${key_path}"
}

# Convert a GitHub URL to use SSH with custom host alias
convert_repo_url_to_ssh() {
  local url="$1"
  local ssh_host_alias="$2"
  
  # Extract owner/repo from various URL formats
  local owner_repo=""
  if [[ "$url" =~ git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ https?://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  else
    # If not a GitHub URL, return as-is
    echo "$url"
    return
  fi
  
  # Remove .git suffix if present
  owner_repo="${owner_repo%.git}"
  
  # Return SSH URL with custom host alias
  echo "git@${ssh_host_alias}:${owner_repo}.git"
}

# ---- Git helpers (run as gitdeploy) ----
git_as_deploy() { sudo -u "${GIT_USER}" bash -lc "$*"; }

# ---- Setup SSH Deploy Key ----
echo "🔑 Setting up SSH deploy key..."
SSH_SETUP_RESULT="$(setup_deploy_key "${APP_NAME}" "${REPO_URL}")"
SSH_HOST_ALIAS="${SSH_SETUP_RESULT%|*}"
DEPLOY_KEY_PATH="${SSH_SETUP_RESULT#*|}"
DEPLOY_KEY_PUB="${DEPLOY_KEY_PATH}.pub"

# Convert repo URL to use SSH with the custom host alias
REPO_URL_SSH="$(convert_repo_url_to_ssh "${REPO_URL}" "${SSH_HOST_ALIAS}")"

echo ""
echo "================================================================"
echo "📋 DEPLOY KEY - ACTION REQUIRED"
echo "================================================================"
echo ""
echo "Please add the following public key as a deploy key to your GitHub repository:"
echo "Repository: ${REPO_URL}"
echo ""
echo "Steps:"
echo "  1. Go to: https://github.com/<owner>/<repo>/settings/keys/new"
echo "  2. Add a title (e.g., 'Deploy key for ${APP_NAME}')"
echo "  3. Paste the following public key:"
echo ""
echo "─────────────────────────────────────────────────────────────────"
if [[ -f "${DEPLOY_KEY_PUB}" ]]; then
  cat "${DEPLOY_KEY_PUB}"
else
  echo "ERROR: Public key file not found at ${DEPLOY_KEY_PUB}"
  echo "Debug info: SSH_SETUP_RESULT=${SSH_SETUP_RESULT}"
  exit 1
fi
echo "─────────────────────────────────────────────────────────────────"
echo ""
echo "  4. Check 'Allow write access' if you need to push branches from this server"
echo "  5. Click 'Add key'"
echo ""
echo "Public key file location: ${DEPLOY_KEY_PUB}"
echo ""
echo "================================================================"
read -rp "Press ENTER once you've added the deploy key to GitHub... " _
echo ""
echo "✓ Continuing with repository access..."
echo ""

branch_exists_remote() {
  git_as_deploy "git ls-remote --heads '${REPO_URL_SSH}' '${1}'" | grep -q "refs/heads/${1}"
}

# Detect default branch
DEFAULT_BRANCH="$(
  git_as_deploy "git ls-remote --symref '${REPO_URL_SSH}' HEAD 2>/dev/null" \
  | sed -nE 's#^ref: refs/heads/([[:graph:]]+)[[:space:]]+HEAD$#\1#p' \
  | head -n1
)"
if [[ -z "${DEFAULT_BRANCH}" ]]; then
  DEFAULT_BRANCH="$(git_as_deploy "git ls-remote '${REPO_URL_SSH}' 2>/dev/null" | awk -F/ '/refs\/heads\/(main|master)$/ {print $NF; exit}')"
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
    git clone '${REPO_URL_SSH}' repo;
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
    # Update remote URL to use the SSH host alias
    git_as_deploy "cd '${target_dir}' && git remote set-url origin '${REPO_URL_SSH}' && git fetch origin '${branch}' && git checkout '${branch}' && git pull origin '${branch}'"
  else
    git_as_deploy "git clone --branch '${branch}' --single-branch '${REPO_URL_SSH}' '${target_dir}'"
  fi
  
  # Keep gitdeploy as owner so it can manage git operations (fetch, reset, etc.)
  # APP_USER is in the group and can read/write via group permissions
  chown -R "${GIT_USER}:${APP_USER}" "${target_dir}"
  chmod -R g+rwX "${target_dir}"
  
  # Set setgid bit on directories so new files inherit the group
  find "${target_dir}" -type d -exec chmod g+s {} \;
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
  cat > "${dir}/ecosystem.config.cjs" <<EOF
module.exports = { apps: [{ name: "${name}", cwd: "${dir}", script: "npm", args: "start", env: { PORT: "${port}", NODE_ENV: "${env}" }, watch: false }] };
EOF
  chown "${APP_USER}:${APP_USER}" "${dir}/ecosystem.config.cjs"
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
    pm2 start ecosystem.config.cjs || pm2 restart ecosystem.config.cjs
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
bash "${SCRIPT_DIR}/setup_webhook_server.sh"

# ---- hooks.json entries for live/dev/staging + secrets ----
python3 - "${WEBHOOK_DIR}/hooks.json" "${APP_NAME}" "${REPO_URL}" "${DEFAULT_BRANCH}" \
         "${LIVE_DIR}" "${DEV_DIR}" "${STAGING_DIR}" \
         "${LIVE_DOMAIN}" "${DEV_DOMAIN}" "${STAGING_DOMAIN}" <<'PY'
import json, os, sys, re, secrets

cfg_path, app_name, repo_url, default_branch, live_dir, dev_dir, staging_dir, live_domain, dev_domain, staging_domain = sys.argv[1:11]

def load():
    with open(cfg_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save(cfg):
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

def parse_owner_repo(url):
    m = re.match(r'^git@github\.com:([^/]+)/([^/]+)\.git$', url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    m = re.match(r'^https?://github\.com/([^/]+)/([^/.]+)(?:\.git)?$', url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    return ""

def get_or_create_secret():
    return secrets.token_hex(32)

cfg = load()
cfg.setdefault("hooks", [])
cfg.setdefault("github", [])

repo_full = parse_owner_repo(repo_url)

def upsert_simple_hook(hooks, hook_id, path, host, dir_path, branch, pm2_name):
    if not host:
        return None
    entry = None
    for h in hooks:
        if h.get("id") == hook_id:
            h.update({
                "type": "simple",
                "path": path,
                "host": host,
                "dir": dir_path,
                "branch": branch,
                "pm2": pm2_name,
            })
            entry = h
            break
    if not entry:
        entry = {
            "type": "simple",
            "id": hook_id,
            "path": path,
            "host": host,
            "dir": dir_path,
            "branch": branch,
            "pm2": pm2_name,
            "secret": get_or_create_secret(),
        }
        hooks.append(entry)
    return entry

live_simple = upsert_simple_hook(
    cfg["hooks"],
    f"{app_name}-live",
    "/_deploy/live",
    live_domain,
    live_dir,
    default_branch,
    f"{app_name}-live",
)

dev_simple = upsert_simple_hook(
    cfg["hooks"],
    f"{app_name}-dev",
    "/_deploy/dev",
    dev_domain,
    dev_dir,
    "dev",
    f"{app_name}-dev",
) if dev_domain else None

staging_simple = upsert_simple_hook(
    cfg["hooks"],
    f"{app_name}-staging",
    "/_deploy/staging",
    staging_domain,
    staging_dir,
    "staging",
    f"{app_name}-staging",
) if staging_domain else None

# GitHub HMAC mapping for this repo (one entry per repo, shared path /_github)
gh = None
if repo_full:
    for g in cfg["github"]:
        if g.get("repo") == repo_full:
            gh = g
            break
    if not gh:
        gh = {
            "id": app_name,
            "path": "/_github",
            "secret": get_or_create_secret(),
            "repo": repo_full,
            "map": {},
        }
        cfg["github"].append(gh)

    gh.setdefault("map", {})
    gh["map"][f"refs/heads/{default_branch}"] = {
        "dir": live_dir,
        "pm2": f"{app_name}-live",
        "branch": default_branch,
    }
    if dev_dir and dev_domain:
        gh["map"]["refs/heads/dev"] = {
            "dir": dev_dir,
            "pm2": f"{app_name}-dev",
            "branch": "dev",
        }
    if staging_dir and staging_domain:
        gh["map"]["refs/heads/staging"] = {
            "dir": staging_dir,
            "pm2": f"{app_name}-staging",
            "branch": "staging",
        }

save(cfg)

print((live_simple or {}).get("secret", ""))
print((dev_simple or {}).get("secret", ""))
print((staging_simple or {}).get("secret", ""))
print((gh or {}).get("secret", ""))
PY

read -r LIVE_HOOK_SECRET || LIVE_HOOK_SECRET=""
read -r DEV_HOOK_SECRET || DEV_HOOK_SECRET=""
read -r STAGING_HOOK_SECRET || STAGING_HOOK_SECRET=""
read -r GH_SECRET || GH_SECRET=""

# restart webhook server to pick up changes
sudo -u "${APP_USER}" bash -lc '
  export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
  pm2 restart deploy-webhooks || true
  pm2 save || true
'

echo
echo "================== APP ADDED/UPDATED =================="
echo "App: ${APP_NAME}"
echo "Repo: ${REPO_URL} (branch: ${DEFAULT_BRANCH})"
echo "Live:    https://${LIVE_DOMAIN} (PORT ${LIVE_PORT})"
[[ -n "${DEV_DOMAIN}" ]] && echo "Dev:     https://${DEV_DOMAIN} (PORT ${DEV_PORT})"
[[ -n "${STAGING_DOMAIN}" ]] && echo "Staging: https://${STAGING_DOMAIN} (PORT ${STAGING_PORT})"
echo
echo "🔑 SSH Deploy Key (add to GitHub repository as deploy key):"
echo "   Public key file: ${DEPLOY_KEY_PUB}"
if [[ -f "${DEPLOY_KEY_PUB}" ]]; then
  echo "   Content:"
  cat "${DEPLOY_KEY_PUB}" | sed 's/^/     /'
fi
echo "   Private key file: ${DEPLOY_KEY_PATH}"
echo "   SSH config alias: ${SSH_HOST_ALIAS}"
echo
echo "Manual deploy webhooks (POST with X-Webhook-Secret):"
echo "  https://${LIVE_DOMAIN}/_deploy/live        Secret: ${LIVE_HOOK_SECRET:-existing}"
[[ -n "${DEV_DOMAIN}" ]] && echo "  https://${DEV_DOMAIN}/_deploy/dev         Secret: ${DEV_HOOK_SECRET:-existing}"
[[ -n "${STAGING_DOMAIN}" ]] && echo "  https://${STAGING_DOMAIN}/_deploy/staging     Secret: ${STAGING_HOOK_SECRET:-existing}"
echo
echo "GitHub webhook (HMAC verified):"
echo "  Payload URL: https://${LIVE_DOMAIN}/_github"
echo "  Secret: ${GH_SECRET:-existing}"
echo "  Mapping:"
echo "    refs/heads/${DEFAULT_BRANCH}  → ${LIVE_DIR}      (pm2: ${APP_NAME}-live)"
[[ -n "${DEV_DOMAIN}" ]] && echo "    refs/heads/dev             → ${DEV_DIR}       (pm2: ${APP_NAME}-dev)"
[[ -n "${STAGING_DOMAIN}" ]] && echo "    refs/heads/staging         → ${STAGING_DIR}   (pm2: ${APP_NAME}-staging)"
echo "========================================================"
