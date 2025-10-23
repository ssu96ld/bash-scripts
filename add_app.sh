#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# 02_add_app.sh
# - Adds/updates a Node app (live/dev/staging)
# - PM2 config & start
# - Nginx vhosts + Certbot
# - Webhook server integration:
#     * simple endpoints (/_deploy/<env>) with per-domain secrets
#     * GitHub HMAC endpoint (/_github) mapped by repo+branch
# - Idempotent: safe to re-run for multiple apps
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3000

# ---- preflight ----
if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

APP_USER="${SUDO_USER:-root}"
APP_HOME="$(eval echo ~${APP_USER})"

# Ensure NVM for PM2 commands
ensure_nvm_pm2() {
  sudo -u "${APP_USER}" bash -lc '
    if [[ ! -d "$HOME/.nvm" ]]; then
      echo "ERROR: NVM is not installed for '"${APP_USER}"' (run 01_setup_server.sh first)"; exit 1
    fi
    export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
    command -v pm2 >/dev/null 2>&1 || npm i -g pm2
  '
}
ensure_nvm_pm2

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

# Robust default branch detection
DEFAULT_BRANCH="$(
  git ls-remote --symref "${REPO_URL}" HEAD 2>/dev/null \
  | sed -nE 's#^ref: refs/heads/([[:graph:]]+)[[:space:]]+HEAD$#\1#p' \
  | head -n1
)"
if [[ -z "${DEFAULT_BRANCH}" ]]; then
  DEFAULT_BRANCH="$(git ls-remote "${REPO_URL}" 2>/dev/null | awk -F/ '/refs\/heads\/(main|master)$/ {print $NF; exit}')"
fi
: "${DEFAULT_BRANCH:=main}"

APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"
LIVE_DIR="${APP_DIR_ROOT}/live"
DEV_DIR="${APP_DIR_ROOT}/dev"
STAGING_DIR="${APP_DIR_ROOT}/staging"
mkdir -p "${APP_DIR_ROOT}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR_ROOT}"

# ----- helpers -----
# port finder: check output of ss (NOT exit code)
find_free_port() {
  local port="$1"
  while :; do
    if [[ -z "$(ss -H -ltn "sport = :$port")" ]]; then
      echo "$port"; return
    fi
    port=$((port+1))
  done
}

branch_exists_remote(){ git ls-remote --heads "$1" "$2" | grep -q "refs/heads/$2"; }

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

clone_or_pull () {
  local branch="$1" target_dir="$2"
  if [[ -d "${target_dir}/.git" ]]; then
    sudo -u "${APP_USER}" bash -lc "cd '${target_dir}' && git fetch origin '${branch}' && git checkout '${branch}' && git pull origin '${branch}'"
  else
    sudo -u "${APP_USER}" bash -lc "git clone --branch '${branch}' --single-branch '${REPO_URL}' '${target_dir}'"
  fi
}

# Parse owner/repo from REPO_URL → e.g. "owner/repo"
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

# ----- ensure dev/staging branches if requested -----
[[ -n "${DEV_DOMAIN}" ]] && ensure_branch_exists_remote "dev"
[[ -n "${STAGING_DOMAIN}" ]] && ensure_branch_exists_remote "staging"

# ----- clone live/dev/staging -----
clone_or_pull "${DEFAULT_BRANCH}" "${LIVE_DIR}"
[[ -n "${DEV_DOMAIN}" ]] && { branch_exists_remote "${REPO_URL}" "dev" && clone_or_pull "dev" "${DEV_DIR}" || sudo -u "${APP_USER}" bash -lc "cp -r '${LIVE_DIR}' '${DEV_DIR}'; cd '${DEV_DIR}'; git checkout -b dev || git checkout dev"; }
[[ -n "${STAGING_DOMAIN}" ]] && { branch_exists_remote "${REPO_URL}" "staging" && clone_or_pull "staging" "${STAGING_DIR}" || sudo -u "${APP_USER}" bash -lc "cp -r '${LIVE_DIR}' '${STAGING_DIR}'; cd '${STAGING_DIR}'; git checkout -b staging || git checkout staging"; }

# ----- assign ports -----
LIVE_PORT="$(find_free_port "${BASE_PORT}")"
NEXT=$((LIVE_PORT+1)); DEV_PORT="$(find_free_port "${NEXT}")"
NEXT=$((DEV_PORT+1)); STAGING_PORT="$(find_free_port "${NEXT}")"
[[ -z "${DEV_DOMAIN}" ]] && DEV_PORT=""
[[ -z "${STAGING_DOMAIN}" ]] && STAGING_PORT=""

# ----- pm2 ecosystem -----
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

# ----- nginx vhosts (include both /_deploy/ and /_github/) -----
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

  # Simple deploy hooks (per-domain)
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
}
make_vhost "${LIVE_DOMAIN}" "${LIVE_PORT}"
[[ -n "${DEV_DOMAIN}" ]] && make_vhost "${DEV_DOMAIN}" "${DEV_PORT}"
[[ -n "${STAGING_DOMAIN}" ]] && make_vhost "${STAGING_DOMAIN}" "${STAGING_PORT}"

nginx -t
systemctl reload nginx

# ----- Certs per domain (best-effort) -----
issue_tls(){ local d="$1"; certbot --nginx -d "$d" --non-interactive --agree-tos --register-unsafely-without-email || echo "WARNING: certbot failed for $d"; }
issue_tls "${LIVE_DOMAIN}"
[[ -n "${DEV_DOMAIN}" ]] && issue_tls "${DEV_DOMAIN}"
[[ -n "${STAGING_DOMAIN}" ]] && issue_tls "${STAGING_DOMAIN}"

# ===== Webhook server integration (multi-app, HMAC) =====

install_or_upgrade_webhook_server(){
  mkdir -p "${WEBHOOK_DIR}"
  # Create hooks.json if missing
  if [[ ! -f "${WEBHOOK_DIR}/hooks.json" ]]; then
    cat > "${WEBHOOK_DIR}/hooks.json" <<JSON
{
  "listenHost": "127.0.0.1",
  "listenPort": ${WEBHOOK_PORT},
  "hooks": [],
  "github": []
}
JSON
    chown "${APP_USER}:${APP_USER}" "${WEBHOOK_DIR}/hooks.json"
  fi

  # Upgrade server.js if it doesn't support multi GitHub/simple host-aware matching
  local needs_upgrade="yes"
  if [[ -f "${WEBHOOK_DIR}/server.js" ]]; then
    if grep -q "MULTI_GITHUB_SUPPORT" "${WEBHOOK_DIR}/server.js"; then
      needs_upgrade="no"
    fi
  fi

  if [[ "${needs_upgrade}" == "yes" ]]; then
    cp -a "${WEBHOOK_DIR}/server.js" "${WEBHOOK_DIR}/server.js.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cat > "${WEBHOOK_DIR}/server.js" <<'JS'
// MULTI_GITHUB_SUPPORT
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exec } = require('child_process');

const cfgPath = path.join(__dirname, 'hooks.json');

function loadCfg() { return JSON.parse(fs.readFileSync(cfgPath, 'utf8')); }
function respond(res, code, obj) { res.writeHead(code, {'Content-Type':'application/json'}); res.end(JSON.stringify(obj)); }

function timingSafeEq(a, b) {
  const A = Buffer.from(a || '');
  const B = Buffer.from(b || '');
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
}
function verifyGitHubSig(buf, secret, hdr) {
  if (!hdr || !hdr.startsWith('sha256=')) return false;
  const h = crypto.createHmac('sha256', secret); h.update(buf);
  const expected = 'sha256=' + h.digest('hex');
  return timingSafeEq(expected, hdr);
}
function runDeploy(dir, branch, pm2Name, cb) {
  const cmds = [
    `cd '${dir.replace(/'/g, `'\\''`)}'`,
    `git fetch --all --prune`,
    `git reset --hard origin/${branch}`,
    `(npm ci || npm install)`,
    `pm2 restart '${pm2Name.replace(/'/g, `'\\''`)}'`
  ].join(' && ');
  exec(cmds, { shell:'/bin/bash' }, (err, stdout, stderr) => {
    if (err) return cb(err, stderr.toString());
    cb(null, stdout.toString());
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const host = (req.headers['host'] || '').split(':')[0];
  const cfg = loadCfg();

  if (req.method === 'GET' && url.pathname === '/_deploy/health') {
    return respond(res, 200, { ok:true, pong:true });
  }

  // ----- simple hooks: prefer host-matched, allow multiple per path -----
  const simpleCandidates = (cfg.hooks || []).filter(h => (h.path === url.pathname) && (h.type === 'simple' || !h.type));
  if (simpleCandidates.length) {
    if (req.method !== 'POST') return respond(res, 405, { ok:false, error:'method not allowed' });
    let use = simpleCandidates.find(h => !!h.host && h.host === host) || simpleCandidates[0];
    const secret = req.headers['x-webhook-secret'];
    if (!secret || secret !== use.secret) return respond(res, 401, { ok:false, error:'unauthorized' });
    return runDeploy(use.dir, use.branch, use.pm2, (err, out) => {
      if (err) return respond(res, 500, { ok:false, error:'deploy failed', details: out });
      return respond(res, 200, { ok:true, result: out, id: use.id, host });
    });
  }

  // ----- GitHub HMAC hooks: allow N entries sharing the same path -----
  const ghCandidates = (cfg.github || []).filter(h => h.path === url.pathname);
  if (ghCandidates.length) {
    if (req.method !== 'POST') return respond(res, 405, { ok:false, error:'method not allowed' });
    const chunks = [];
    req.on('data', d => chunks.push(d));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      const event = req.headers['x-github-event'] || '';
      if (event === 'ping') return respond(res, 200, { ok:true, pong:true });

      let handled = false, lastErr = null;
      for (const gh of ghCandidates) {
        try {
          const sig = req.headers['x-hub-signature-256'];
          if (!verifyGitHubSig(buf, gh.secret, sig)) continue; // try next candidate
          const payload = JSON.parse(buf.toString('utf8'));
          const fullName = payload?.repository?.full_name;
          const ref = payload?.ref;
          if (gh.repo && fullName !== gh.repo) { lastErr = `repo mismatch ${fullName}`; continue; }
          const target = gh.map?.[ref];
          if (!target) { lastErr = `no mapping for ${ref}`; continue; }
          return runDeploy(target.dir, target.branch, target.pm2, (err, out) => {
            if (err) return respond(res, 500, { ok:false, error:'deploy failed', details: out, repo: fullName, ref });
            return respond(res, 200, { ok:true, result: out, repo: fullName, ref, id: gh.id });
          });
        } catch (e) { lastErr = e.message; }
      }
      if (!handled) return respond(res, 200, { ok:true, ignored: lastErr || 'no candidate matched' });
    });
    return;
  }

  return respond(res, 404, { ok:false, error:'not found' });
});

const cfg = loadCfg();
server.listen(cfg.listenPort, cfg.listenHost, () => {
  console.log(`Webhook server listening on ${cfg.listenHost}:${cfg.listenPort}`);
});
JS
    chown "${APP_USER}:${APP_USER}" "${WEBHOOK_DIR}/server.js"
  fi

  # Ensure pm2 process is up
  sudo -u "${APP_USER}" bash -lc '
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    cd "'"${WEBHOOK_DIR}"'"
    npm init -y >/dev/null 2>&1 || true
    pm2 start server.js --name deploy-webhooks || pm2 restart deploy-webhooks
    pm2 save
  '
}

install_or_upgrade_webhook_server

# ----- update hooks.json (idempotent upserts) -----
python3 - "$WEBHOOK_DIR/hooks.json" "$APP_NAME" "$REPO_URL" "$REPO_FULL_NAME" "$DEFAULT_BRANCH" "$APP_DIR_ROOT" "$LIVE_DIR" "$DEV_DIR" "$STAGING_DIR" "$LIVE_DOMAIN" "$DEV_DOMAIN" "$STAGING_DOMAIN" <<'PY'
import json, os, sys, secrets, re
cfg_path, app_name, repo_url, repo_full, default_branch, app_root, live_dir, dev_dir, stg_dir, live_dom, dev_dom, stg_dom = sys.argv[1:13]

# Load or create cfg
if os.path.exists(cfg_path):
    with open(cfg_path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
else:
    cfg = {"listenHost":"127.0.0.1","listenPort":9000,"hooks":[],"github":[]}

cfg.setdefault("hooks", [])
cfg.setdefault("github", [])

def get_or_create_secret():
    return secrets.token_hex(32)

def upsert_simple(id_, path, host, dir_, branch, pm2name):
    # find by id
    for h in cfg["hooks"]:
        if h.get("id")==id_:
            # keep existing secret; update others
            h.update({"type":"simple","path":path,"host":host,"dir":dir_,"branch":branch,"pm2":pm2name})
            return h
    # else insert
    entry = {"type":"simple","id":id_,"path":path,"host":host,"dir":dir_,"branch":branch,"pm2":pm2name,"secret":get_or_create_secret()}
    cfg["hooks"].append(entry)
    return entry

def parse_owner_repo(url):
    # git@github.com:owner/repo.git  OR  https://github.com/owner/repo(.git)
    m = re.match(r'^git@github\.com:([^/]+)/([^/]+)\.git$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    m = re.match(r'^https?://github\.com/([^/]+)/([^/.]+)(?:\.git)?$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    return ""

repo_full = repo_full or parse_owner_repo(repo_url)

def upsert_github(id_, path, secret, repo_fullname, mappings):
    # find by id or repo
    for g in cfg["github"]:
        if g.get("id")==id_ or (repo_fullname and g.get("repo")==repo_fullname):
            if not g.get("secret"): g["secret"]=secret or get_or_create_secret()
            if path: g["path"]=path
            if repo_fullname: g["repo"]=repo_fullname
            g.setdefault("map", {})
            g["map"].update(mappings or {})
            return g
    entry = {
        "id": id_,
        "path": path or "/_github",
        "secret": secret or get_or_create_secret(),
        "repo": repo_fullname,
        "map": mappings or {}
    }
    cfg["github"].append(entry)
    return entry

# LIVE mapping to default branch ref
mappings = {}
if live_dom and live_dir:
    mappings[f"refs/heads/{default_branch}"] = { "dir": live_dir, "pm2": f"{app_name}-live", "branch": default_branch }
if dev_dom and dev_dir:
    mappings["refs/heads/dev"] = { "dir": dev_dir, "pm2": f"{app_name}-dev", "branch": "dev" }
if stg_dom and stg_dir:
    mappings["refs/heads/staging"] = { "dir": stg_dir, "pm2": f"{app_name}-staging", "branch": "staging" }

# Upsert simple per-domain hooks (manual trigger)
simple_live = upsert_simple(f"{app_name}-live", "/_deploy/live", live_dom, live_dir, default_branch, f"{app_name}-live") if live_dom else None
simple_dev  = upsert_simple(f"{app_name}-dev", "/_deploy/dev", dev_dom, dev_dir, "dev", f"{app_name}-dev") if dev_dom else None
simple_stg  = upsert_simple(f"{app_name}-staging", "/_deploy/staging", stg_dom, stg_dir, "staging", f"{app_name}-staging") if stg_dom else None

# Upsert GitHub HMAC entry (shared /_github path, multi-app supported server-side)
gh = upsert_github(app_name, "/_github", None, repo_full, mappings)

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)

# Print secrets for shell consumption
def out_secret(s):
    sys.stdout.write((s or "") + "\n")
for s in (simple_live.get("secret") if simple_live else "",
          simple_dev.get("secret") if simple_dev else "",
          simple_stg.get("secret") if simple_stg else "",
          gh.get("secret") if gh else ""):
    out_secret(s)
PY

# Read the 4 lines printed by Python: live/dev/staging simple secrets + GH secret
read -r LIVE_SECRET || LIVE_SECRET=""
read -r DEV_SECRET  || DEV_SECRET=""
read -r STAGING_SECRET || STAGING_SECRET=""
read -r GH_SECRET   || GH_SECRET=""

# Restart webhook server to pick changes
sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 restart deploy-webhooks; pm2 save'

# ----- Summary -----
echo
echo "================== APP ADDED/UPDATED =================="
echo "App: ${APP_NAME}  Repo: ${REPO_URL}  (default branch: ${DEFAULT_BRANCH})"
echo "Live:    https://${LIVE_DOMAIN}    (PORT ${LIVE_PORT})"
[[ -n "${DEV_DOMAIN}" ]] && echo "Dev:     https://${DEV_DOMAIN}     (PORT ${DEV_PORT})"
[[ -n "${STAGING_DOMAIN}" ]] && echo "Staging: https://${STAGING_DOMAIN}  (PORT ${STAGING_PORT})"
echo
echo "Manual deploy webhooks (POST with X-Webhook-Secret):"
echo "  Live:    https://${LIVE_DOMAIN}/_deploy/live       Secret: ${LIVE_SECRET:-existing}"
[[ -n "${DEV_DOMAIN}" ]] && echo "  Dev:     https://${DEV_DOMAIN}/_deploy/dev        Secret: ${DEV_SECRET:-existing}"
[[ -n "${STAGING_DOMAIN}" ]] && echo "  Staging: https://${STAGING_DOMAIN}/_deploy/staging    Secret: ${STAGING_SECRET:-existing}"
echo
echo "GitHub webhook (HMAC verified):"
echo "  Payload URL: https://${LIVE_DOMAIN}/_github"
echo "  Secret: ${GH_SECRET:-existing}"
echo "  Repo: ${REPO_FULL_NAME:-<could-not-parse>}"
echo "  Branch mapping:"
echo "    refs/heads/${DEFAULT_BRANCH}  → ${LIVE_DIR}    (pm2: ${APP_NAME}-live)"
[[ -n "${DEV_DOMAIN}" ]] && echo "    refs/heads/dev             → ${DEV_DIR}     (pm2: ${APP_NAME}-dev)"
[[ -n "${STAGING_DOMAIN}" ]] && echo "    refs/heads/staging         → ${STAGING_DIR} (pm2: ${APP_NAME}-staging)"
echo
echo "Next: In GitHub → ${REPO_FULL_NAME} → Settings → Webhooks:"
echo "  • Add webhook  → Payload URL: https://${LIVE_DOMAIN}/_github"
echo "  • Content type: application/json"
echo "  • Secret: ${GH_SECRET:-<existing>}"
echo "  • Events: Just the 'push' event"
echo "========================================================"
